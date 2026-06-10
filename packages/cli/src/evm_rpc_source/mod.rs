use anyhow::Context;
use napi_derive::napi;

mod client;

use client::{JsonRpcClient, RpcError};

#[napi(object)]
pub struct EvmRpcClientConfig {
    pub url: String,
    pub http_req_timeout_millis: Option<i64>,
}

#[napi]
pub struct EvmRpcClient {
    inner: JsonRpcClient,
}

#[napi]
impl EvmRpcClient {
    #[napi(factory)]
    pub fn new(cfg: EvmRpcClientConfig) -> napi::Result<EvmRpcClient> {
        let http_req_timeout_millis = cfg
            .http_req_timeout_millis
            .filter(|v| *v > 0)
            .map_or(JsonRpcClient::default_http_req_timeout_millis(), |v| {
                v as u64
            });
        let inner = JsonRpcClient::new(cfg.url, http_req_timeout_millis).map_err(map_err)?;
        Ok(EvmRpcClient { inner })
    }

    #[napi]
    pub async fn get_height(&self) -> napi::Result<i64> {
        let height = self.inner.get_height().await.map_err(rpc_error_to_napi)?;
        height.try_into().context("convert height").map_err(map_err)
    }
}

/// Encodes JSON-RPC errors as a JSON payload in the napi error's message.
/// The ReScript side parses it back into a structured exception, keeping
/// the provider's code and message intact across the boundary.
fn rpc_error_to_napi(e: RpcError) -> napi::Error {
    match e {
        RpcError::JsonRpc { code, message } => {
            let payload = serde_json::json!({
                "kind": "JsonRpcError",
                "code": code,
                "message": message,
            })
            .to_string();
            napi::Error::from_reason(payload)
        }
        RpcError::Other(e) => map_err(e),
    }
}

fn map_err(e: anyhow::Error) -> napi::Error {
    napi::Error::from_reason(format!("{e:#}"))
}
