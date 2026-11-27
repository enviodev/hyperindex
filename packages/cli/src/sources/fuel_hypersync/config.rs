use anyhow::{Context, Result};

/// The HyperFuel client options the indexer sets.
pub(crate) struct ClientConfig {
    pub url: String,
    pub api_token: String,
    pub http_req_timeout_millis: u64,
}

impl TryFrom<ClientConfig> for hyperfuel_client::ClientConfig {
    type Error = anyhow::Error;

    fn try_from(config: ClientConfig) -> Result<Self> {
        // hyperfuel_client::ClientConfig holds a `url::Url`; go through serde so
        // it parses the endpoint without us taking a direct dependency on the
        // url crate.
        let json = serde_json::json!({
            "url": config.url,
            "api_token": config.api_token,
            "http_req_timeout_millis": config.http_req_timeout_millis,
            // Retries belong to the indexer. The client sleeps between attempts
            // even when it makes only one, on the real clock, so every delay is
            // zero too.
            "max_num_retries": 0,
            "retry_backoff_ms": 0,
            "retry_base_ms": 0,
            "retry_ceiling_ms": 0,
        });
        serde_json::from_value(json).context("build hyperfuel client config")
    }
}
