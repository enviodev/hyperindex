use anyhow::Context;
use napi_derive::napi;

mod client;

use client::{JsonRpcClient, RpcError};

#[napi(object)]
#[derive(Default, Clone)]
pub struct RpcClientConfig {
    pub url: String,
}

#[napi]
pub struct RpcClient {
    inner: JsonRpcClient,
}

#[napi]
impl RpcClient {
    #[napi(factory)]
    pub fn new(cfg: RpcClientConfig) -> napi::Result<RpcClient> {
        let inner = JsonRpcClient::new(cfg.url).map_err(map_err)?;
        Ok(RpcClient { inner })
    }

    #[napi]
    pub async fn get_height(&self) -> napi::Result<i64> {
        let height = self.inner.get_height().await.map_err(rpc_error_to_napi)?;
        height.try_into().context("convert height").map_err(map_err)
    }
}

fn rpc_error_to_napi(e: RpcError) -> napi::Error {
    napi::Error::from_reason(format!("{e}"))
}

fn map_err(e: anyhow::Error) -> napi::Error {
    napi::Error::from_reason(format!("{e:#}"))
}
