use std::time::Duration;

use napi_derive::napi;

use super::transport::{Format, Transport};

/// Configuration for the hypersync client.
///
/// There are no retry settings: every failure, a rate limit above all, goes
/// straight back to SourceManager, which backs off, surfaces the throttling in
/// the TUI and can fail over to another source.
#[napi(object)]
#[derive(Default, Clone)]
pub struct ClientConfig {
    pub url: String,
    pub api_token: String,
    pub http_req_timeout_millis: Option<i64>,
    pub serialization_format: Option<SerializationFormat>,
    pub enable_query_caching: Option<bool>,
    /// Log level for the underlying Rust logger (e.g. "info", "debug", "trace",
    /// or a directive like "envio=debug"). RUST_LOG env var takes
    /// precedence. Only the first client's value takes effect.
    pub log_level: Option<String>,
}

const DEFAULT_HTTP_REQ_TIMEOUT_MILLIS: u64 = 30_000;

impl ClientConfig {
    pub(super) fn into_transport(self, user_agent: String) -> anyhow::Result<Transport> {
        let format = match self.serialization_format.unwrap_or_default() {
            SerializationFormat::Json => Format::Json,
            SerializationFormat::CapnProto => Format::CapnProto {
                should_cache_queries: self.enable_query_caching.unwrap_or_default(),
            },
        };
        let timeout_millis = self
            .http_req_timeout_millis
            .filter(|millis| *millis >= 0)
            .map_or(DEFAULT_HTTP_REQ_TIMEOUT_MILLIS, |millis| millis as u64);
        Transport::new(
            &self.url,
            self.api_token,
            user_agent,
            Duration::from_millis(timeout_millis),
            format,
        )
    }
}

#[napi(string_enum)]
#[derive(Default, Clone)]
pub enum SerializationFormat {
    #[default]
    Json,
    CapnProto,
}
