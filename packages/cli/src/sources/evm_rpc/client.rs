use anyhow::{Context, Result};
use reqwest::header::{HeaderMap, HeaderName, HeaderValue};
use serde::de::DeserializeOwned;
use serde::Deserialize;
use serde_json::json;
use serde_json::value::RawValue;
use std::collections::HashMap;
use std::time::Instant;
use tokio::sync::{Semaphore, SemaphorePermit};

use super::classify::is_rate_limited;
use crate::evm::rpc_fields::parse_hex_u64;
use crate::sources::request_stats::{RequestStat, Stats};

/// JSON-RPC level errors are kept separate from transport/parse failures:
/// provider error messages carry block-range hints the caller inspects. The
/// failures that say the provider could not deliver the answer it was asked
/// for, rather than that it is unreachable, have their own variants.
#[derive(Debug)]
pub enum RpcError {
    JsonRpc {
        code: i64,
        message: String,
    },
    /// The provider refused the request for how often it is being asked.
    RateLimited {
        /// The JSON-RPC code, when the refusal came as a JSON-RPC error.
        code: Option<i64>,
        message: String,
        /// The provider's `Retry-After`, when it sent one in seconds.
        retry_after_millis: Option<u64>,
    },
    /// No answer within the request timeout.
    Timeout(anyhow::Error),
    /// An answer arrived but can't be read as one: a body cut off mid-read,
    /// something other than JSON-RPC, or a result of the wrong shape, such as
    /// `null` where a list was due.
    MalformedResponse(anyhow::Error),
    Other(anyhow::Error),
}

impl std::fmt::Display for RpcError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            RpcError::JsonRpc { code, message } => write!(f, "JSON-RPC error {code}: {message}"),
            RpcError::RateLimited {
                code: Some(code),
                message,
                ..
            } => write!(f, "rate limited, JSON-RPC error {code}: {message}"),
            RpcError::RateLimited { message, .. } => write!(f, "rate limited: {message}"),
            RpcError::Timeout(err) | RpcError::MalformedResponse(err) | RpcError::Other(err) => {
                write!(f, "{err:#}")
            }
        }
    }
}

#[derive(Deserialize)]
struct JsonRpcErrorObject {
    code: i64,
    message: String,
}

// `result` must distinguish present-but-null (a successful "not found"
// response for methods like eth_getBlockByNumber) from a missing field.
// A plain `Option` maps JSON null to `None`, so route present values
// through `deserialize_with` which captures null as `Some(raw "null")`.
fn raw_value_as_some<'de, D: serde::Deserializer<'de>>(
    deserializer: D,
) -> Result<Option<Box<RawValue>>, D::Error> {
    Box::<RawValue>::deserialize(deserializer).map(Some)
}

#[derive(Deserialize)]
struct JsonRpcResponse {
    #[serde(default, deserialize_with = "raw_value_as_some")]
    result: Option<Box<RawValue>>,
    error: Option<JsonRpcErrorObject>,
}

pub struct JsonRpcClient {
    http: reqwest::Client,
    url: String,
    /// Reported back on a timeout, where naming the limit that was hit is the
    /// whole of what the caller can act on.
    request_timeout_millis: u64,
    /// Bounds the requests this source has in flight at once. The block,
    /// transaction and receipt reads a page fans out to scale with how many logs
    /// its range holds, which no block interval can express: a single dense
    /// block plans thousands of reads.
    permits: Semaphore,
    /// The timing of every request that finished and has not been reported
    /// yet. Requests are billed per source rather than per call, so whichever
    /// call reports next carries what finished since the last one did — a
    /// read that several partitions shared counts once, whoever issued it.
    stats: Stats,
}

impl JsonRpcClient {
    /// High enough to keep a healthy provider's pipe full, low enough that the
    /// burst above stays a queue rather than a stampede.
    pub const fn default_max_concurrent_requests() -> usize {
        100
    }

    /// Waits for this source's turn to call the provider.
    async fn acquire(&self) -> SemaphorePermit<'_> {
        self.permits
            .acquire()
            .await
            .expect("the request semaphore is never closed")
    }

    pub fn new(
        url: String,
        request_timeout_millis: u64,
        max_concurrent_requests: usize,
        headers: Option<HashMap<String, String>>,
    ) -> Result<Self> {
        let mut builder = reqwest::Client::builder()
            .timeout(std::time::Duration::from_millis(request_timeout_millis));
        if let Some(headers) = headers {
            let mut header_map = HeaderMap::with_capacity(headers.len());
            for (name, value) in headers {
                let header_name = HeaderName::try_from(name.as_str())
                    .with_context(|| format!("invalid RPC header name {name:?}"))?;
                let header_value = HeaderValue::try_from(value.as_str())
                    .with_context(|| format!("invalid value for RPC header {name:?}"))?;
                header_map.insert(header_name, header_value);
            }
            builder = builder.default_headers(header_map);
        }
        let http = builder.build().context("build http client")?;
        Ok(Self {
            http,
            url,
            request_timeout_millis,
            permits: Semaphore::new(max_concurrent_requests),
            stats: Stats::default(),
        })
    }

    /// The requests that finished since the last call, for the caller to
    /// report.
    pub fn take_stats(&self) -> Vec<RequestStat> {
        self.stats.take()
    }

    /// Every request is timed here, whether or not it answered: it was made,
    /// and is billed.
    pub async fn request<T: DeserializeOwned>(
        &self,
        method: &str,
        params: serde_json::Value,
    ) -> Result<T, RpcError> {
        self.request_recorded_as(method, method, params).await
    }

    /// A request whose timing is reported under `stat_method` rather than the
    /// JSON-RPC method, so a request made for a reason of its own is counted
    /// apart from the ones it shares a method with.
    pub async fn request_recorded_as<T: DeserializeOwned>(
        &self,
        stat_method: &str,
        method: &str,
        params: serde_json::Value,
    ) -> Result<T, RpcError> {
        // Queueing is not part of how long a request took, so the turn is taken
        // before the clock starts.
        let permit = self.acquire().await;
        let started = Instant::now();
        let result = self.send(permit, method, params).await;
        self.stats
            .record(stat_method, started.elapsed().as_secs_f64());
        result
    }

    /// The caller's turn lasts exactly as long as the provider is working on
    /// the request.
    async fn send<T: DeserializeOwned>(
        &self,
        permit: SemaphorePermit<'_>,
        method: &str,
        params: serde_json::Value,
    ) -> Result<T, RpcError> {
        let body = json!({
            "method": method,
            "params": params,
            "id": 1,
            "jsonrpc": "2.0",
        });
        let response = self
            .http
            .post(&self.url)
            .json(&body)
            .send()
            .await
            .map_err(|err| {
                if err.is_timeout() {
                    RpcError::Timeout(anyhow::anyhow!(
                        "{method} took longer than {}ms",
                        self.request_timeout_millis
                    ))
                } else {
                    RpcError::Other(
                        anyhow::Error::new(err).context(format!("send {method} request")),
                    )
                }
            })?;

        let status = response.status();
        // An HTTP-date `Retry-After` would need the wall clock, so only the
        // delta-seconds form is read; the configured backoff covers the rest.
        // Zero is left to it too, or a provider repeating it would be asked
        // again with no wait at all.
        let retry_after_millis = response
            .headers()
            .get(reqwest::header::RETRY_AFTER)
            .and_then(|value| value.to_str().ok())
            .and_then(|value| value.trim().parse::<u64>().ok())
            .filter(|seconds| *seconds > 0)
            .map(|seconds| seconds.saturating_mul(1000));
        let bytes = response.bytes().await.map_err(|err| {
            let timed_out = err.is_timeout();
            let err = anyhow::Error::new(err).context(format!("read {method} response body"));
            if timed_out {
                RpcError::Timeout(err)
            } else {
                RpcError::MalformedResponse(err)
            }
        })?;
        // Decoding what came back is this process's work, not the provider's,
        // so the next queued request gets the turn before it starts.
        drop(permit);

        // Providers report JSON-RPC errors under non-200 statuses too (e.g.
        // 429/400), so parse the body first and fall back to the HTTP status
        // only when there's no JSON-RPC envelope to read. A 429 is still
        // throttling either way, unless its message limits the request itself.
        let snippet = || String::from_utf8_lossy(&bytes[..bytes.len().min(512)]).into_owned();
        // For a body that is no JSON-RPC envelope, whether parseable or not.
        let rate_limited_by_status = |snippet: &str| {
            (!status.is_success() && is_rate_limited(status.as_u16(), None, snippet)).then(|| {
                RpcError::RateLimited {
                    code: None,
                    message: format!("HTTP {status} for {method}: {snippet}"),
                    retry_after_millis,
                }
            })
        };
        let parsed: JsonRpcResponse = match serde_json::from_slice(&bytes) {
            Ok(parsed) => parsed,
            Err(e) => {
                let snippet = snippet();
                if let Some(rate_limited) = rate_limited_by_status(&snippet) {
                    return Err(rate_limited);
                }
                let err = anyhow::anyhow!(
                    "invalid JSON-RPC response for {method} (HTTP {status}): {e}; body: {snippet}"
                );
                // An error status with a body that isn't JSON-RPC is a gateway
                // failing, not an answer that came back damaged.
                return Err(if status.is_success() {
                    RpcError::MalformedResponse(err)
                } else {
                    RpcError::Other(err)
                });
            }
        };

        if let Some(error) = parsed.error {
            if is_rate_limited(status.as_u16(), Some(error.code), &error.message) {
                return Err(RpcError::RateLimited {
                    code: Some(error.code),
                    message: error.message,
                    retry_after_millis,
                });
            }
            return Err(RpcError::JsonRpc {
                code: error.code,
                message: error.message,
            });
        }
        match parsed.result {
            Some(result) => serde_json::from_str(result.get())
                .with_context(|| format!("parse {method} result"))
                .map_err(RpcError::MalformedResponse),
            None => Err(rate_limited_by_status(&snippet()).unwrap_or_else(|| {
                RpcError::MalformedResponse(anyhow::anyhow!(
                    "JSON-RPC response for {method} (HTTP {status}) has neither result nor error"
                ))
            })),
        }
    }

    pub async fn get_height(&self) -> Result<u64, RpcError> {
        let result: String = self.request("eth_blockNumber", json!([])).await?;
        parse_hex_u64(&result).map_err(RpcError::Other)
    }
}
