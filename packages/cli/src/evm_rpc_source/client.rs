use anyhow::{Context, Result};
use serde::de::DeserializeOwned;
use serde::Deserialize;
use serde_json::json;

/// JSON-RPC level errors are kept separate from transport/parse failures:
/// provider error messages carry block-range hints the caller inspects.
#[derive(Debug)]
pub enum RpcError {
    JsonRpc { code: i64, message: String },
    Other(anyhow::Error),
}

impl std::fmt::Display for RpcError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            RpcError::JsonRpc { code, message } => {
                write!(f, "JSON-RPC error {code}: {message}")
            }
            RpcError::Other(e) => write!(f, "{e:#}"),
        }
    }
}

#[derive(Deserialize)]
struct JsonRpcErrorObject {
    code: i64,
    message: String,
}

#[derive(Deserialize)]
struct JsonRpcResponse {
    result: Option<serde_json::Value>,
    error: Option<JsonRpcErrorObject>,
}

pub struct JsonRpcClient {
    http: reqwest::Client,
    url: String,
}

impl JsonRpcClient {
    pub fn new(url: String) -> Result<Self> {
        let http = reqwest::Client::builder()
            .build()
            .context("build http client")?;
        Ok(Self { http, url })
    }

    pub async fn request<T: DeserializeOwned>(
        &self,
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
            .with_context(|| format!("send {method} request"))
            .map_err(RpcError::Other)?;

        let status = response.status();
        let bytes = response
            .bytes()
            .await
            .with_context(|| format!("read {method} response body"))
            .map_err(RpcError::Other)?;

        // Providers report JSON-RPC errors under non-200 statuses too (e.g.
        // 429/400), so parse the body first and fall back to the HTTP status
        // only when there's no JSON-RPC envelope to read.
        let parsed: JsonRpcResponse = match serde_json::from_slice(&bytes) {
            Ok(parsed) => parsed,
            Err(e) => {
                let snippet = String::from_utf8_lossy(&bytes[..bytes.len().min(512)]).into_owned();
                return Err(RpcError::Other(anyhow::anyhow!(
                    "invalid JSON-RPC response for {method} (HTTP {status}): {e}; body: {snippet}"
                )));
            }
        };

        if let Some(error) = parsed.error {
            return Err(RpcError::JsonRpc {
                code: error.code,
                message: error.message,
            });
        }
        match parsed.result {
            Some(result) => serde_json::from_value(result)
                .with_context(|| format!("parse {method} result"))
                .map_err(RpcError::Other),
            None => Err(RpcError::Other(anyhow::anyhow!(
                "JSON-RPC response for {method} (HTTP {status}) has neither result nor error"
            ))),
        }
    }

    pub async fn get_height(&self) -> Result<u64, RpcError> {
        let result: String = self.request("eth_blockNumber", json!([])).await?;
        parse_hex_u64(&result).map_err(RpcError::Other)
    }
}

pub fn parse_hex_u64(s: &str) -> Result<u64> {
    let hex = s
        .strip_prefix("0x")
        .or_else(|| s.strip_prefix("0X"))
        .with_context(|| format!("expected 0x-prefixed hex quantity, got {s:?}"))?;
    u64::from_str_radix(hex, 16).with_context(|| format!("invalid hex quantity {s:?}"))
}

// HTTP and JSON-RPC envelope behavior (success, error bodies, non-200
// statuses) is covered end-to-end through the napi layer in
// scenarios/test_codegen/test/lib_tests/RpcClient_test.res.
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_hex_u64_cases() {
        let results = (
            parse_hex_u64("0x0").unwrap(),
            parse_hex_u64("0x1b4").unwrap(),
            parse_hex_u64("0X1B4").unwrap(),
            parse_hex_u64("1b4").is_err(),
            parse_hex_u64("0xzz").is_err(),
        );
        assert_eq!(results, (0, 436, 436, true, true));
    }
}
