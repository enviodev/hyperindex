use std::time::Duration;

use crate::hypersync_http::{HttpClient, HttpVersion};

/// The Solana HyperSync client options the indexer sets.
///
/// There are no retry settings: every failure has to reach SourceManager,
/// which backs off on the indexer's clock, surfaces the throttling and can
/// fail over.
pub(crate) struct SvmClientConfig {
    pub url: String,
    pub api_token: String,
    pub http_req_timeout_millis: u64,
}

impl SvmClientConfig {
    pub(super) fn into_http_client(self, user_agent: String) -> anyhow::Result<HttpClient> {
        HttpClient::new(
            &self.url,
            (!self.api_token.is_empty()).then_some(self.api_token),
            user_agent,
            HttpVersion::Http1,
            Duration::from_millis(self.http_req_timeout_millis),
        )
    }
}
