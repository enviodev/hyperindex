use std::time::Duration;

use napi_derive::napi;

use super::transport::{Format, Transport};

/// The HyperSync client options the indexer sets.
///
/// There are no retry settings: every failure, a rate limit above all, goes
/// straight back to SourceManager, which backs off on the indexer's clock,
/// surfaces the throttling and can fail over to another source.
pub(crate) struct ClientConfig {
    pub url: String,
    pub api_token: String,
    pub http_req_timeout_millis: u64,
    pub serialization_format: SerializationFormat,
    pub enable_query_caching: bool,
    /// Filter for the client's own logging, e.g. "info" or a directive like
    /// "envio=debug".
    pub log_filter: String,
}

impl ClientConfig {
    pub(super) fn into_transport(self, user_agent: String) -> anyhow::Result<Transport> {
        let format = match self.serialization_format {
            SerializationFormat::Json => Format::Json,
            SerializationFormat::CapnProto => Format::CapnProto {
                should_cache_queries: self.enable_query_caching,
            },
        };
        Transport::new(
            &self.url,
            self.api_token,
            user_agent,
            Duration::from_millis(self.http_req_timeout_millis),
            format,
        )
    }
}

#[napi(string_enum)]
#[derive(Clone, Copy)]
pub enum SerializationFormat {
    Json,
    CapnProto,
}
