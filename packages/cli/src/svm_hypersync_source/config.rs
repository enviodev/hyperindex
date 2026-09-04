use std::time::Duration;

use napi_derive::napi;

/// Configuration for the Solana HyperSync client.
#[napi(object)]
#[derive(Default, Clone)]
pub struct SvmClientConfig {
    pub url: String,
    pub api_token: Option<String>,
    pub http_req_timeout_millis: Option<i64>,
    /// Defaults to no retries — see the `From` impl.
    pub max_num_retries: Option<i64>,
    pub retry_base_ms: Option<i64>,
    pub retry_ceiling_ms: Option<i64>,
}

impl From<SvmClientConfig> for hypersync_client_solana::config::ClientConfig {
    fn from(c: SvmClientConfig) -> Self {
        let default = Self::default();
        Self {
            url: c.url,
            bearer_token: c.api_token,
            http_req_timeout: c
                .http_req_timeout_millis
                .filter(|v| *v >= 0)
                .map(|v| Duration::from_millis(v as u64))
                .unwrap_or(default.http_req_timeout),
            // Retries belong to the indexer, not the binary client. Every
            // failure the client would swallow — a rate limit above all — has
            // to reach SourceManager, which backs off, surfaces the throttling
            // in the TUI and can fail over to another source; none of that can
            // happen while a retry loop sleeps inside a single napi call.
            max_num_retries: c
                .max_num_retries
                .and_then(|v| u32::try_from(v).ok())
                .unwrap_or(0),
            retry_base_ms: c
                .retry_base_ms
                .filter(|v| *v >= 0)
                .map(|v| v as u64)
                .unwrap_or(default.retry_base_ms),
            retry_ceiling_ms: c
                .retry_ceiling_ms
                .filter(|v| *v >= 0)
                .map(|v| v as u64)
                .unwrap_or(default.retry_ceiling_ms),
            // A sleep inside the client is invisible to the indexer: it holds
            // the request open while SourceManager's backoff, failover and TUI
            // throttling all sit idle. Surface the 429 instead.
            proactive_rate_limit_sleep: false,
        }
    }
}
