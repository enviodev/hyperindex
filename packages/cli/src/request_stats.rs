use napi_derive::napi;

/// Timing for one backend request. Multiple entries may be returned for a
/// single source operation when that operation paginates internally.
#[napi(object)]
pub struct RequestStat {
    pub method: String,
    pub seconds: f64,
}

/// Preserve timings when a napi request fails. ReScript decodes this payload,
/// records the stats, then retries using the original message/cause.
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
    napi::Error::from_reason(
        serde_json::json!({
            "kind": "RequestFailed",
            "message": error.reason,
            "requestStats": request_stats,
        })
        .to_string(),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn failed_request_payload_keeps_message_and_timings() {
        let error = error_with_request_stats(
            napi::Error::from_reason("RATE_LIMITED:2500"),
            &[RequestStat {
                method: "getBlockHashes".to_string(),
                seconds: 0.25,
            }],
        );
        let payload: serde_json::Value = serde_json::from_str(&error.reason).unwrap();
        assert_eq!(payload["kind"], "RequestFailed");
        assert_eq!(payload["message"], "RATE_LIMITED:2500");
        assert_eq!(payload["requestStats"][0]["method"], "getBlockHashes");
        assert_eq!(payload["requestStats"][0]["seconds"], 0.25);
    }
}
