use std::time::Duration;

use napi_derive::napi;

use crate::hypersync_http::{HttpClient, HttpVersion};

/// Configuration for the Solana HyperSync client.
///
/// There are no retry settings: every failure, a rate limit above all, goes
/// straight back to SourceManager, which backs off, surfaces the throttling in
/// the TUI and can fail over to another source.
#[napi(object)]
#[derive(Default, Clone)]
pub struct SvmClientConfig {
    pub url: String,
    pub api_token: Option<String>,
    pub http_req_timeout_millis: Option<i64>,
}

const DEFAULT_HTTP_REQ_TIMEOUT: Duration = Duration::from_secs(30);

impl SvmClientConfig {
    pub(super) fn into_http_client(self, user_agent: String) -> anyhow::Result<HttpClient> {
        anyhow::ensure!(!self.url.is_empty(), "url must not be empty");
        let timeout = self
            .http_req_timeout_millis
            .filter(|millis| *millis >= 0)
            .map_or(DEFAULT_HTTP_REQ_TIMEOUT, |millis| {
                Duration::from_millis(millis as u64)
            });
        HttpClient::new(
            &self.url,
            self.api_token,
            user_agent,
            HttpVersion::Http1,
            timeout,
        )
    }
}
