use std::future::Future;
use std::time::Duration;

/// Gives up on `request` after `timeout`, for a client whose own timeout is set
/// for backfill and can't be shortened per request. Dropping the future
/// cancels the HTTP request it was waiting on. Without a timeout, only the
/// client's own applies.
pub(crate) async fn within<T>(
    timeout: Option<Duration>,
    what: &str,
    request: impl Future<Output = anyhow::Result<T>>,
) -> anyhow::Result<T> {
    let Some(timeout) = timeout else {
        return request.await;
    };
    match tokio::time::timeout(timeout, request).await {
        Ok(result) => result,
        Err(_) => Err(anyhow::anyhow!(
            "{what} took longer than {}ms",
            timeout.as_millis()
        )),
    }
}

/// A timeout the indexer passes across napi, in milliseconds.
pub(crate) fn positive_millis(millis: i64) -> anyhow::Result<Duration> {
    u64::try_from(millis)
        .ok()
        .filter(|millis| *millis > 0)
        .map(Duration::from_millis)
        .ok_or_else(|| anyhow::anyhow!("a request timeout must be positive, got {millis}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn gives_up_on_a_request_past_the_timeout_and_keeps_a_faster_answer() {
        let answer_after = |millis| async move {
            tokio::time::sleep(Duration::from_millis(millis)).await;
            Ok::<_, anyhow::Error>(millis)
        };
        let timeout = Some(Duration::from_millis(50));
        let (fast, slow, unbounded) = (
            within(timeout, "fast", answer_after(1)).await,
            within(timeout, "slow", answer_after(200)).await,
            within(None, "unbounded", answer_after(200)).await,
        );
        assert_eq!(
            (
                fast.map_err(|e| e.to_string()),
                slow.map_err(|e| e.to_string()),
                unbounded.map_err(|e| e.to_string()),
            ),
            (
                Ok(1),
                Err("slow took longer than 50ms".to_string()),
                Ok(200)
            )
        );
    }
}
