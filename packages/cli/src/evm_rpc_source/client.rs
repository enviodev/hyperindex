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

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::sync::oneshot;

    /// Serves a single HTTP response and sends the raw request it received
    /// back through the returned channel.
    async fn spawn_one_shot_server(
        status_line: &'static str,
        body: &'static str,
    ) -> (String, oneshot::Receiver<String>) {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let (request_sender, request_receiver) = oneshot::channel();
        tokio::spawn(async move {
            let (mut socket, _) = listener.accept().await.unwrap();
            let mut request = Vec::new();
            let mut buf = [0u8; 4096];
            loop {
                let n = socket.read(&mut buf).await.unwrap();
                if n == 0 {
                    break;
                }
                request.extend_from_slice(&buf[..n]);
                if let Some(headers_end) = request
                    .windows(4)
                    .position(|w| w == b"\r\n\r\n")
                    .map(|p| p + 4)
                {
                    let headers = String::from_utf8_lossy(&request[..headers_end]).to_lowercase();
                    let content_length = headers
                        .lines()
                        .find_map(|l| l.strip_prefix("content-length:"))
                        .and_then(|v| v.trim().parse::<usize>().ok())
                        .unwrap_or(0);
                    if request.len() >= headers_end + content_length {
                        break;
                    }
                }
            }
            let response = format!(
                "HTTP/1.1 {status_line}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                body.len(),
            );
            socket.write_all(response.as_bytes()).await.unwrap();
            let _ = request_sender.send(String::from_utf8_lossy(&request).into_owned());
        });
        (format!("http://{addr}"), request_receiver)
    }

    #[tokio::test]
    async fn get_height_parses_hex_result_and_sends_jsonrpc_request() {
        let (url, request_receiver) =
            spawn_one_shot_server("200 OK", r#"{"jsonrpc":"2.0","id":1,"result":"0x1b4"}"#).await;
        let client = JsonRpcClient::new(url).unwrap();

        let height = client.get_height().await.unwrap();
        assert_eq!(height, 436);

        let request = request_receiver.await.unwrap();
        let request_body = request.split("\r\n\r\n").nth(1).unwrap();
        let parsed: serde_json::Value = serde_json::from_str(request_body).unwrap();
        assert_eq!(
            parsed,
            json!({"method": "eth_blockNumber", "params": [], "id": 1, "jsonrpc": "2.0"})
        );
    }

    #[tokio::test]
    async fn get_height_surfaces_jsonrpc_error() {
        let (url, _request) = spawn_one_shot_server(
            "200 OK",
            r#"{"jsonrpc":"2.0","id":1,"error":{"code":-32005,"message":"limited to a 1000 blocks range"}}"#,
        )
        .await;
        let client = JsonRpcClient::new(url).unwrap();

        let err = client.get_height().await.unwrap_err();
        match err {
            RpcError::JsonRpc { code, message } => {
                assert_eq!(
                    (code, message),
                    (-32005, "limited to a 1000 blocks range".to_string())
                )
            }
            RpcError::Other(e) => panic!("unexpected RpcError::Other: {e:?}"),
        }
    }

    #[tokio::test]
    async fn jsonrpc_error_with_non_200_status_is_still_parsed() {
        let (url, _request) = spawn_one_shot_server(
            "429 Too Many Requests",
            r#"{"jsonrpc":"2.0","id":1,"error":{"code":-32029,"message":"rate limited"}}"#,
        )
        .await;
        let client = JsonRpcClient::new(url).unwrap();

        let err = client.get_height().await.unwrap_err();
        match err {
            RpcError::JsonRpc { code, message } => {
                assert_eq!((code, message), (-32029, "rate limited".to_string()))
            }
            RpcError::Other(e) => panic!("unexpected RpcError::Other: {e:?}"),
        }
    }

    #[tokio::test]
    async fn non_json_body_reports_http_status_and_snippet() {
        let (url, _request) = spawn_one_shot_server("502 Bad Gateway", "upstream exploded").await;
        let client = JsonRpcClient::new(url).unwrap();

        let err = client.get_height().await.unwrap_err();
        match err {
            RpcError::Other(e) => {
                let message = format!("{e:#}");
                assert!(
                    message.contains("502") && message.contains("upstream exploded"),
                    "unexpected message: {message}"
                )
            }
            RpcError::JsonRpc { .. } => panic!("unexpected RpcError::JsonRpc"),
        }
    }

    #[tokio::test]
    async fn response_without_result_or_error_fails() {
        let (url, _request) = spawn_one_shot_server("200 OK", r#"{"jsonrpc":"2.0","id":1}"#).await;
        let client = JsonRpcClient::new(url).unwrap();

        let err = client.get_height().await.unwrap_err();
        match err {
            RpcError::Other(e) => {
                let message = format!("{e:#}");
                assert!(
                    message.contains("neither result nor error"),
                    "unexpected message: {message}"
                )
            }
            RpcError::JsonRpc { .. } => panic!("unexpected RpcError::JsonRpc"),
        }
    }

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
