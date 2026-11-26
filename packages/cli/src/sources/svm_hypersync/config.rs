use std::time::Duration;

/// The Solana HyperSync client options the indexer sets.
#[derive(Clone)]
pub(crate) struct SvmClientConfig {
    pub url: String,
    pub api_token: String,
    pub http_req_timeout_millis: u64,
}

impl From<SvmClientConfig> for hypersync_client_solana::config::ClientConfig {
    fn from(c: SvmClientConfig) -> Self {
        Self {
            url: c.url,
            bearer_token: Some(c.api_token),
            http_req_timeout: Duration::from_millis(c.http_req_timeout_millis),
            // Retries belong to the indexer, not the client: every failure has
            // to reach SourceManager, which backs off on the indexer's clock,
            // surfaces the throttling and can fail over. A sleep inside the
            // client is invisible to all of that.
            max_num_retries: 0,
            proactive_rate_limit_sleep: false,
            ..Self::default()
        }
    }
}
