use anyhow::{Context, Result};
use napi_derive::napi;

/// Configuration for the HyperFuel client.
#[napi(object)]
#[derive(Default, Clone)]
pub struct ClientConfig {
    pub url: String,
    pub api_token: String,
    pub http_req_timeout_millis: Option<i64>,
    /// For a request near the head: heights, and item queries that say they
    /// are near it. Absent, `http_req_timeout_millis` applies to those too.
    pub near_head_req_timeout_millis: Option<i64>,
}

impl TryFrom<ClientConfig> for hyperfuel_client::ClientConfig {
    type Error = anyhow::Error;

    fn try_from(config: ClientConfig) -> Result<Self> {
        // hyperfuel_client::ClientConfig holds a `url::Url`; go through serde so
        // it parses the (already validated) endpoint without us taking a direct
        // dependency on the url crate.
        let json = serde_json::json!({
            "url": config.url,
            "api_token": config.api_token,
            // Positive, or left to the client's default.
            "http_req_timeout_millis": config.http_req_timeout_millis.filter(|millis| *millis > 0),
            // Retries are handled by the indexer, not the binary client.
            "max_num_retries": 0,
        });
        serde_json::from_value(json).context("build hyperfuel client config")
    }
}
