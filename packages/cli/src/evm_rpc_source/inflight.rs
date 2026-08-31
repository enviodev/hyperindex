//! Coalesces concurrent requests for the same key onto one in-flight future.
//!
//! This is deduplication, not caching: an entry lives exactly as long as its
//! request is in flight, so a key requested again afterwards is fetched again.
//! What a response is worth keeping is decided by the block and transaction
//! stores, which already own the merge, prune and rollback lifecycle that
//! decides when data stops being valid — a second cache here would have to
//! duplicate that lifecycle and could outlive a reorg.
//!
//! There is deliberately no concurrency limit. The natural bound is the page
//! itself, and a provider that cannot keep up answers with an error that the
//! caller's adaptive block interval reacts to by narrowing the range — which
//! regulates the load at the layer that knows what the load is for.

use std::collections::HashMap;
use std::future::Future;
use std::hash::Hash;
use std::sync::{Arc, Mutex};

use futures_util::future::{BoxFuture, FutureExt, Shared};
use futures_util::TryFutureExt;

/// Waiters share one result, so a failure reaches all of them; `Arc` because
/// the error type itself need not be cloneable.
type SharedFetch<V, E> = Shared<BoxFuture<'static, Result<V, Arc<E>>>>;

pub(crate) struct Inflight<K, V, E> {
    pending: Mutex<HashMap<K, SharedFetch<V, E>>>,
}

impl<K, V, E> Default for Inflight<K, V, E> {
    fn default() -> Self {
        Self {
            pending: Mutex::new(HashMap::new()),
        }
    }
}

impl<K: Eq + Hash + Clone, V: Clone, E> Inflight<K, V, E> {
    /// Resolve `key`, running `make` only if no request for it is already in
    /// flight. Every caller that arrives while one is gets that request's
    /// result — value or error alike.
    pub(crate) async fn get<F, Fut>(&self, key: K, make: F) -> Result<V, Arc<E>>
    where
        F: FnOnce() -> Fut,
        Fut: Future<Output = Result<V, E>> + Send + 'static,
        V: Send + 'static,
        E: Send + Sync + 'static,
    {
        let shared = {
            let mut pending = self.pending.lock().unwrap();
            match pending.get(&key) {
                Some(existing) => existing.clone(),
                None => {
                    let fetch = make().map_err(Arc::new).boxed().shared();
                    pending.insert(key.clone(), fetch.clone());
                    fetch
                }
            }
        };

        let result = shared.clone().await;

        // Only retire the entry this call awaited. A later request for the same
        // key may already have installed its own future, and removing by key
        // alone would drop that one and let a third request start a duplicate.
        let mut pending = self.pending.lock().unwrap();
        if pending
            .get(&key)
            .is_some_and(|current| current.ptr_eq(&shared))
        {
            pending.remove(&key);
        }
        result
    }

    /// Forget every in-flight request. Waiters already holding a future still
    /// receive its result; what changes is that nothing new joins them, so a
    /// request issued after this point observes the chain afresh. Called on a
    /// reorg, where an in-flight response may describe an orphaned fork.
    pub(crate) fn clear(&self) {
        self.pending.lock().unwrap().clear();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::time::Duration;

    type TestInflight = Inflight<u8, u32, String>;

    /// A loader that counts its calls and takes long enough that a second
    /// request arrives while it is still running.
    fn counting(
        calls: &Arc<AtomicUsize>,
        value: u32,
    ) -> impl FnOnce() -> BoxFuture<'static, Result<u32, String>> {
        let calls = calls.clone();
        move || {
            calls.fetch_add(1, Ordering::SeqCst);
            async move {
                tokio::time::sleep(Duration::from_millis(10)).await;
                Ok(value)
            }
            .boxed()
        }
    }

    fn failing(
        calls: &Arc<AtomicUsize>,
    ) -> impl FnOnce() -> BoxFuture<'static, Result<u32, String>> {
        let calls = calls.clone();
        move || {
            calls.fetch_add(1, Ordering::SeqCst);
            async move {
                tokio::time::sleep(Duration::from_millis(10)).await;
                Err("boom".to_string())
            }
            .boxed()
        }
    }

    #[tokio::test(start_paused = true)]
    async fn concurrent_requests_for_one_key_share_a_single_fetch() {
        let inflight = TestInflight::default();
        let calls = Arc::new(AtomicUsize::new(0));
        let (a, b, c) = tokio::join!(
            inflight.get(1, counting(&calls, 7)),
            inflight.get(1, counting(&calls, 7)),
            inflight.get(1, counting(&calls, 7)),
        );
        assert_eq!(
            (
                a.unwrap(),
                b.unwrap(),
                c.unwrap(),
                calls.load(Ordering::SeqCst)
            ),
            (7, 7, 7, 1)
        );
    }

    #[tokio::test(start_paused = true)]
    async fn distinct_keys_fetch_independently() {
        let inflight = TestInflight::default();
        let calls = Arc::new(AtomicUsize::new(0));
        let (a, b) = tokio::join!(
            inflight.get(1, counting(&calls, 10)),
            inflight.get(2, counting(&calls, 20)),
        );
        assert_eq!(
            (a.unwrap(), b.unwrap(), calls.load(Ordering::SeqCst)),
            (10, 20, 2)
        );
    }

    #[tokio::test(start_paused = true)]
    async fn a_settled_key_is_fetched_again_rather_than_cached() {
        // Deduplication only: once the request is done the entry is gone, and
        // what is worth keeping lives in the stores instead.
        let inflight = TestInflight::default();
        let calls = Arc::new(AtomicUsize::new(0));
        let first = inflight.get(1, counting(&calls, 7)).await;
        let second = inflight.get(1, counting(&calls, 7)).await;
        assert_eq!(
            (
                first.unwrap(),
                second.unwrap(),
                calls.load(Ordering::SeqCst)
            ),
            (7, 7, 2)
        );
    }

    #[tokio::test(start_paused = true)]
    async fn a_failure_reaches_every_waiter_and_the_next_request_retries() {
        let inflight = TestInflight::default();
        let calls = Arc::new(AtomicUsize::new(0));
        let (a, b) = tokio::join!(
            inflight.get(1, failing(&calls)),
            inflight.get(1, failing(&calls)),
        );
        let retried = inflight.get(1, counting(&calls, 7)).await;
        assert_eq!(
            (
                a.unwrap_err().as_str(),
                b.unwrap_err().as_str(),
                retried.unwrap(),
                calls.load(Ordering::SeqCst)
            ),
            ("boom", "boom", 7, 2)
        );
    }

    #[tokio::test(start_paused = true)]
    async fn clear_stops_later_requests_joining_an_in_flight_fetch() {
        // After a reorg an in-flight response may describe an orphaned fork, so
        // a request made afterwards must start its own fetch.
        let inflight = TestInflight::default();
        let calls = Arc::new(AtomicUsize::new(0));
        let joined = inflight.get(1, counting(&calls, 7));
        let cleared = async {
            tokio::task::yield_now().await;
            inflight.clear();
            inflight.get(1, counting(&calls, 7)).await
        };
        let (a, b) = tokio::join!(joined, cleared);
        assert_eq!(
            (a.unwrap(), b.unwrap(), calls.load(Ordering::SeqCst)),
            (7, 7, 2)
        );
    }
}
