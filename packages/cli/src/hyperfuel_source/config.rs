use anyhow::{Context, Result};
use napi_derive::napi;
use std::num::NonZeroU64;
use url::Url;

/// Configuration for the HyperFuel client.
#[napi(object)]
#[derive(Default, Clone)]
pub struct ClientConfig {
    pub url: String,
    pub bearer_token: Option<String>,
    pub http_req_timeout_millis: Option<i64>,
}

impl TryFrom<ClientConfig> for hyperfuel_client::ClientConfig {
    type Error = anyhow::Error;

    fn try_from(config: ClientConfig) -> Result<Self> {
        Ok(Self {
            url: Some(Url::parse(&config.url).context("parse hyperfuel url")?),
            bearer_token: config.bearer_token,
            http_req_timeout_millis: config
                .http_req_timeout_millis
                .and_then(|v| u64::try_from(v).ok())
                .and_then(NonZeroU64::new),
            // Retries are handled by the indexer, not the binary client.
            max_num_retries: Some(0),
            retry_backoff_ms: None,
            retry_base_ms: None,
            retry_ceiling_ms: None,
        })
    }
}
