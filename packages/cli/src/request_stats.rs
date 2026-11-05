use napi_derive::napi;

pub(crate) const QUERY_BLOCK_HASHES_METHOD: &str = "getBlockHashes";

/// Marks the queried block as not yet available on the backend instance that
/// served the request, with the block number following the prefix. ReScript maps
/// it back to `Source.SourceBehindHead` so SourceManager owns the retry — it
/// logs, backs off, and can fail over, none of which an in-process loop could
/// do. Keep in sync with `HyperSync.res`.
pub(crate) const SOURCE_BEHIND_HEAD_PREFIX: &str = "SOURCE_BEHIND_HEAD:";

pub(crate) fn source_behind_head_err(block_number: i64) -> napi::Error {
    napi::Error::from_reason(format!("{SOURCE_BEHIND_HEAD_PREFIX}{block_number}"))
}

/// Marks a rate-limited backend response, with the milliseconds until the
/// window resets following the prefix. ReScript maps it back to
/// `Source.RateLimited` so SourceManager owns the wait — it surfaces the
/// throttling in the TUI and can fail over, neither of which the native
/// client's own in-place sleep could do. Keep in sync with `HyperSync.res`.
pub(crate) const RATE_LIMITED_PREFIX: &str = "RATE_LIMITED:";

pub(crate) fn rate_limited_err(reset_ms: u64) -> napi::Error {
    napi::Error::from_reason(format!("{RATE_LIMITED_PREFIX}{reset_ms}"))
}

/// Marks a napi error's reason as a structured native-failure envelope (the
/// `{message, requestStats}` JSON follows). ReScript decodes the timings only
/// when the reason starts with this exact prefix, so an unrelated error message
/// — even one that happens to be JSON — is never mistaken for one of ours, and
/// its original cause is preserved untouched. Keep in sync with `Source.res`.
pub(crate) const NATIVE_FAILURE_PREFIX: &str = "ENVIO_NATIVE_FAILURE:";

/// Timing for one backend request. Multiple entries may be returned for a
/// single source operation when that operation paginates internally.
#[napi(object)]
#[derive(Debug, PartialEq)]
pub struct RequestStat {
    pub method: String,
    pub seconds: f64,
}

/// Preserve timings when a napi request fails, by wrapping the underlying error
/// in a prefixed envelope. ReScript decodes it, records the stats, then retries
/// using the original message/cause.
pub(crate) fn error_with_request_stats(
    error: napi::Error,
    request_stats: &[RequestStat],
) -> napi::Error {
    let request_stats: Vec<_> = request_stats
        .iter()
        .map(|stat| {
            serde_json::json!({
                "method": stat.method,
                "seconds": stat.seconds,
            })
        })
        .collect();
    let payload = serde_json::json!({
        "message": error.reason,
        "requestStats": request_stats,
    });
    napi::Error::from_reason(format!("{NATIVE_FAILURE_PREFIX}{payload}"))
}

/// A recoverable condition a native call's error names.
#[derive(Debug, PartialEq)]
pub(crate) enum Marker {
    RateLimited { reset_ms: u32 },
    BehindHead { block_number: i64 },
    None,
}

/// What a failed native call reported, read back off its error.
#[derive(Debug, PartialEq)]
pub(crate) struct NativeFailure {
    pub message: String,
    pub request_stats: Vec<RequestStat>,
    pub marker: Marker,
}

fn marker_value<T: std::str::FromStr>(message: &str, prefix: &str) -> Option<Option<T>> {
    message
        .strip_prefix(prefix)
        .map(|value| value.parse::<T>().ok())
}

/// Undoes [`error_with_request_stats`] and the marker prefixes. An error that
/// is neither keeps its message whole.
pub(crate) fn read_native_failure(error: &napi::Error) -> NativeFailure {
    let (message, request_stats) = error
        .reason
        .strip_prefix(NATIVE_FAILURE_PREFIX)
        .and_then(|payload| serde_json::from_str::<serde_json::Value>(payload).ok())
        .and_then(|payload| {
            let message = payload["message"].as_str()?.to_string();
            let request_stats = payload["requestStats"]
                .as_array()?
                .iter()
                .map(|stat| {
                    Some(RequestStat {
                        method: stat["method"].as_str()?.to_string(),
                        seconds: stat["seconds"].as_f64()?,
                    })
                })
                .collect::<Option<Vec<_>>>()?;
            Some((message, request_stats))
        })
        .unwrap_or_else(|| (error.reason.clone(), Vec::new()));
    let marker = if let Some(reset_ms) = marker_value(&message, RATE_LIMITED_PREFIX) {
        Marker::RateLimited {
            reset_ms: reset_ms.unwrap_or(1000),
        }
    } else if let Some(block_number) = marker_value(&message, SOURCE_BEHIND_HEAD_PREFIX) {
        Marker::BehindHead {
            block_number: block_number.unwrap_or(0),
        }
    } else {
        Marker::None
    };
    NativeFailure {
        message,
        request_stats,
        marker,
    }
}

/// Collects request timings until a source operation reports them.
#[derive(Default)]
pub(crate) struct Stats(std::sync::Mutex<Vec<RequestStat>>);

impl Stats {
    pub(crate) fn record(&self, method: &str, seconds: f64) {
        self.0.lock().unwrap().push(RequestStat {
            method: method.to_string(),
            seconds,
        });
    }

    pub(crate) fn take(&self) -> Vec<RequestStat> {
        std::mem::take(&mut *self.0.lock().unwrap())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn failed_request_payload_keeps_message_and_timings() {
        let error = error_with_request_stats(
            napi::Error::from_reason("RATE_LIMITED:2500"),
            &[RequestStat {
                method: QUERY_BLOCK_HASHES_METHOD.to_string(),
                seconds: 0.25,
            }],
        );
        let reason = &error.reason;
        assert!(reason.starts_with(NATIVE_FAILURE_PREFIX));
        let payload: serde_json::Value =
            serde_json::from_str(&reason[NATIVE_FAILURE_PREFIX.len()..]).unwrap();
        assert_eq!(payload["message"], "RATE_LIMITED:2500");
        assert_eq!(
            payload["requestStats"][0]["method"],
            QUERY_BLOCK_HASHES_METHOD
        );
        assert_eq!(payload["requestStats"][0]["seconds"], 0.25);
    }

    #[test]
    fn reads_back_a_marked_failure_with_its_timings() {
        let error = error_with_request_stats(
            source_behind_head_err(42),
            &[RequestStat {
                method: QUERY_BLOCK_HASHES_METHOD.to_string(),
                seconds: 0.25,
            }],
        );
        assert_eq!(
            read_native_failure(&error),
            NativeFailure {
                message: "SOURCE_BEHIND_HEAD:42".to_string(),
                request_stats: vec![RequestStat {
                    method: QUERY_BLOCK_HASHES_METHOD.to_string(),
                    seconds: 0.25,
                }],
                marker: Marker::BehindHead { block_number: 42 },
            }
        );
    }

    #[test]
    fn reads_a_failure_without_an_envelope() {
        assert_eq!(
            read_native_failure(&rate_limited_err(2500)),
            NativeFailure {
                message: "RATE_LIMITED:2500".to_string(),
                request_stats: Vec::new(),
                marker: Marker::RateLimited { reset_ms: 2500 },
            }
        );
        assert_eq!(
            read_native_failure(&napi::Error::from_reason("connection refused")),
            NativeFailure {
                message: "connection refused".to_string(),
                request_stats: Vec::new(),
                marker: Marker::None,
            }
        );
    }
}
