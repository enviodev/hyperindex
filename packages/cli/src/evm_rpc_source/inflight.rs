//! Coalesces concurrent requests for the same key onto one in-flight future.
//!
//! This is deduplication, not caching: an entry lives exactly as long as some
//! caller is waiting on its request, so a key requested again afterwards is
//! fetched again.
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
use std::sync::Mutex;

use futures_util::future::{BoxFuture, FutureExt, Shared};

/// Waiters share one outcome, so whatever the request produced — including a
/// failure — reaches all of them.
type SharedFetch<V> = Shared<BoxFuture<'static, V>>;

struct Entry<V> {
    fetch: SharedFetch<V>,
    /// How many callers are awaiting `fetch` right now. The entry is retired
    /// when the last of them leaves, so what stays joinable is exactly what
    /// someone is still driving.
    waiters: usize,
}

pub(crate) struct Inflight<K, V> {
    pending: Mutex<HashMap<K, Entry<V>>>,
}

impl<K, V> Default for Inflight<K, V> {
    fn default() -> Self {
        Self {
            pending: Mutex::new(HashMap::new()),
        }
    }
}

impl<K: Eq + Hash + Clone, V: Clone> Inflight<K, V> {
    /// Resolve `key`, running `make` only if no request for it is already in
    /// flight. Every caller that arrives while one is gets that request's
    /// outcome.
    pub(crate) async fn get<F, Fut>(&self, key: K, make: F) -> V
    where
        F: FnOnce() -> Fut,
        Fut: Future<Output = V> + Send + 'static,
        V: Send + 'static,
    {
        let shared = {
            let mut pending = self.pending.lock().unwrap();
            let entry = pending.entry(key.clone()).or_insert_with(|| Entry {
                fetch: make().boxed().shared(),
                waiters: 0,
            });
            entry.waiters += 1;
            entry.fetch.clone()
        };

        // A drop guard rather than cleanup after the await: cancellation is
        // routine here — the whole page races a timeout, and one failed read
        // drops its siblings — so the claim has to be released on every way out.
        let _retire = Retire {
            pending: &self.pending,
            key: &key,
            shared: &shared,
        };
        shared.clone().await
    }

    /// Forget every in-flight request. Waiters already holding a future still
    /// receive its result; what changes is that nothing new joins them, so a
    /// request issued after this point observes the chain afresh. Called on a
    /// reorg, where an in-flight response may describe an orphaned fork.
    pub(crate) fn clear(&self) {
        self.pending.lock().unwrap().clear();
    }
}

/// Drops one caller's claim on an entry, and the entry itself once no caller
/// is left to drive it.
struct Retire<'a, K: Eq + Hash, V> {
    pending: &'a Mutex<HashMap<K, Entry<V>>>,
    key: &'a K,
    shared: &'a SharedFetch<V>,
}

impl<K: Eq + Hash, V> Drop for Retire<'_, K, V> {
    fn drop(&mut self) {
        let mut pending = self.pending.lock().unwrap();
        let Some(entry) = pending.get_mut(self.key) else {
            return;
        };
        // Only the entry this call is actually waiting on. `clear` may have
        // dropped it and a later request installed its own, which this call
        // has no claim on and must not disturb.
        if !entry.fetch.ptr_eq(self.shared) {
            return;
        }
        entry.waiters -= 1;
        if entry.waiters == 0 {
            pending.remove(self.key);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::Arc;
    use std::time::Duration;

    type TestInflight = Inflight<u8, Result<u32, String>>;

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
    async fn a_cancelled_request_is_retired_rather_than_left_to_be_joined() {
        // Cancellation is routine here: the whole page races a timeout, and one
        // failed read drops its siblings. An entry left behind would be joined
        // by the next request for that key and answered with the cancelled
        // attempt's response — deduplication silently turned into a cache that
        // nothing invalidates, holding a view of the chain from before a reorg.
        let inflight = TestInflight::default();
        let calls = Arc::new(AtomicUsize::new(0));
        let cancelled = tokio::time::timeout(
            Duration::from_millis(1),
            inflight.get(1, counting(&calls, 7)),
        )
        .await;

        let fresh = inflight.get(1, counting(&calls, 99)).await;
        assert_eq!(
            (
                cancelled.is_err(),
                inflight.pending.lock().unwrap().len(),
                fresh.unwrap(),
                calls.load(Ordering::SeqCst),
            ),
            (true, 0, 99, 2)
        );
    }

    #[tokio::test(start_paused = true)]
    async fn a_cancelled_waiter_leaves_the_request_for_the_others_to_join() {
        // Partitions are address slices, so several of them read the same head
        // block at once. One page timing out retires only its own claim: the
        // request is still being driven by the others, and a page arriving
        // afterwards must join it rather than ask the provider again.
        let inflight = TestInflight::default();
        let calls = Arc::new(AtomicUsize::new(0));
        let cancelled = tokio::time::timeout(
            Duration::from_millis(1),
            inflight.get(1, counting(&calls, 7)),
        );
        let staying = inflight.get(1, counting(&calls, 7));
        let joining = async {
            tokio::time::sleep(Duration::from_millis(5)).await;
            inflight.get(1, counting(&calls, 7)).await
        };
        let (cancelled, staying, joining) = tokio::join!(cancelled, staying, joining);
        assert_eq!(
            (
                cancelled.is_err(),
                staying.unwrap(),
                joining.unwrap(),
                calls.load(Ordering::SeqCst),
            ),
            (true, 7, 7, 1)
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
