use napi_derive::napi;

pub(crate) const QUERY_BLOCK_HASHES_METHOD: &str = "getBlockHashes";

/// Marks a napi error's reason as a structured native-failure envelope (the
/// `{message, requestStats}` JSON follows). ReScript decodes the timings only
/// when the reason starts with this exact prefix, so an unrelated error message
/// — even one that happens to be JSON — is never mistaken for one of ours, and
/// its original cause is preserved untouched. Keep in sync with `Source.res`.
pub(crate) const NATIVE_FAILURE_PREFIX: &str = "ENVIO_NATIVE_FAILURE:";

/// Timing for one backend request. Multiple entries may be returned for a
/// single source operation when that operation paginates internally.
#[napi(object)]
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
}
