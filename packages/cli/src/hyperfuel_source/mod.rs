use anyhow::Context;
use napi_derive::napi;

mod config;
mod query;
mod types;

use config::ClientConfig;
use query::Query;
use types::{convert_response, QueryResponse};

#[napi]
pub struct HyperfuelClient {
    inner: hyperfuel_client::Client,
}

#[napi]
impl HyperfuelClient {
    #[napi(factory)]
    pub fn new(cfg: ClientConfig) -> napi::Result<HyperfuelClient> {
        let client_config: hyperfuel_client::ClientConfig =
            cfg.try_into().context("build config").map_err(map_err)?;
        let inner = hyperfuel_client::Client::new(client_config)
            .context("build client")
            .map_err(map_err)?;
        Ok(HyperfuelClient { inner })
    }

    #[napi]
    pub async fn get_selected_data(&self, query: Query) -> napi::Result<QueryResponse> {
        let query: hyperfuel_client::net_types::Query =
            query.try_into().context("parse query").map_err(map_err)?;
        let res = self.inner.get_arrow(&query).await.map_err(|e| {
            // The client embeds a `{:?}` debug dump in its error message; keep
            // only the first line so it stays readable on retries.
            let message = format!("{e}");
            let summary = message.lines().next().unwrap_or(message.as_str());
            napi::Error::from_reason(format!("Failed to get data from HyperFuel: {summary}"))
        })?;
        Ok(convert_response(res))
    }
}

fn map_err(e: anyhow::Error) -> napi::Error {
    napi::Error::from_reason(format!("{:?}", e))
}
