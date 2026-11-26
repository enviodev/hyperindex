use napi_derive::napi;

/// The HyperSync client options the indexer sets.
#[derive(Clone)]
pub(crate) struct ClientConfig {
    pub url: String,
    pub api_token: String,
    pub http_req_timeout_millis: u64,
    pub serialization_format: SerializationFormat,
    pub enable_query_caching: bool,
    /// Filter for the client's own logging, e.g. "info" or a directive like
    /// "hypersync_client=debug".
    pub log_filter: String,
}

impl From<ClientConfig> for hypersync_client::ClientConfig {
    fn from(config: ClientConfig) -> Self {
        let serialization_format = match config.serialization_format {
            SerializationFormat::Json => hypersync_client::SerializationFormat::Json,
            SerializationFormat::CapnProto => hypersync_client::SerializationFormat::CapnProto {
                should_cache_queries: config.enable_query_caching,
            },
        };
        Self {
            url: config.url,
            api_token: config.api_token,
            http_req_timeout_millis: config.http_req_timeout_millis,
            // Retries belong to the indexer, not the client. Every failure the
            // client would swallow — a rate limit above all — has to reach
            // SourceManager, which backs off on the indexer's clock, surfaces
            // the throttling and can fail over. The client sleeps between
            // attempts even when it makes only one, on the real clock, so every
            // delay is zero too.
            max_num_retries: 0,
            retry_backoff_ms: 0,
            retry_base_ms: 0,
            retry_ceiling_ms: 0,
            serialization_format,
            proactive_rate_limit_sleep: false,
        }
    }
}

#[napi(string_enum)]
#[derive(Clone, Copy)]
pub enum SerializationFormat {
    Json,
    CapnProto,
}
