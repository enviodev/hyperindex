use anyhow::{Context, Result};
use napi_derive::napi;

/// Configuration for the HyperFuel client.
#[napi(object)]
#[derive(Default, Clone)]
pub struct ClientConfig {
    pub url: String,
    pub bearer_token: Option<String>,
}

impl TryFrom<ClientConfig> for hyperfuel_client::ClientConfig {
    type Error = anyhow::Error;

    fn try_from(config: ClientConfig) -> Result<Self> {
        // hyperfuel_client::ClientConfig holds a `url::Url`; go through serde so
        // it parses the (already validated) endpoint without us taking a direct
        // dependency on the url crate.
        let json = serde_json::json!({
            "url": config.url,
            "bearer_token": config.bearer_token,
            // Retries are handled by the indexer, not the binary client.
            "max_num_retries": 0,
        });
        serde_json::from_value(json).context("build hyperfuel client config")
    }
}
