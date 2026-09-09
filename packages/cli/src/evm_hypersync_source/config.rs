use napi_derive::napi;

/// Configuration for the hypersync client.
#[napi(object)]
#[derive(Default, Clone)]
pub struct ClientConfig {
    pub url: String,
    pub api_token: String,
    pub http_req_timeout_millis: Option<i64>,
    /// Defaults to no retries — see the `From` impl.
    pub max_num_retries: Option<i64>,
    pub retry_backoff_ms: Option<i64>,
    pub retry_base_ms: Option<i64>,
    pub retry_ceiling_ms: Option<i64>,
    pub enable_checksum_addresses: Option<bool>,
    pub serialization_format: Option<SerializationFormat>,
    pub enable_query_caching: Option<bool>,
    /// Log level for the underlying Rust logger (e.g. "info", "debug", "trace",
    /// or a directive like "hypersync_client=debug"). RUST_LOG env var takes
    /// precedence. Only the first client's value takes effect.
    pub log_level: Option<String>,
}

impl From<ClientConfig> for hypersync_client::ClientConfig {
    fn from(config: ClientConfig) -> Self {
        use hypersync_client::ClientConfig as Cfg;
        let serialization_format = match config.serialization_format.unwrap_or_default() {
            SerializationFormat::Json => hypersync_client::SerializationFormat::Json,
            SerializationFormat::CapnProto => {
                let should_cache_queries = config.enable_query_caching.unwrap_or_default();
                hypersync_client::SerializationFormat::CapnProto {
                    should_cache_queries,
                }
            }
        };
        Self {
            url: config.url,
            api_token: config.api_token,
            http_req_timeout_millis: config
                .http_req_timeout_millis
                .filter(|v| *v >= 0)
                .map_or(Cfg::default_http_req_timeout_millis(), |v| v as u64),
            // Retries belong to the indexer, not the binary client. Every
            // failure the client would swallow — a rate limit above all — has
            // to reach SourceManager, which backs off, surfaces the throttling
            // in the TUI and can fail over to another source; none of that can
            // happen while a retry loop sleeps inside a single napi call.
            max_num_retries: config
                .max_num_retries
                .and_then(|v| usize::try_from(v).ok())
                .unwrap_or(0),
            retry_backoff_ms: config
                .retry_backoff_ms
                .filter(|v| *v >= 0)
                .map_or(Cfg::default_retry_backoff_ms(), |v| v as u64),
            retry_base_ms: config
                .retry_base_ms
                .filter(|v| *v >= 0)
                .map_or(Cfg::default_retry_base_ms(), |v| v as u64),
            retry_ceiling_ms: config
                .retry_ceiling_ms
                .filter(|v| *v >= 0)
                .map_or(Cfg::default_retry_ceiling_ms(), |v| v as u64),
            serialization_format,
            proactive_rate_limit_sleep: false,
        }
    }
}

#[napi(string_enum)]
#[derive(Default, Clone)]
pub enum SerializationFormat {
    #[default]
    Json,
    CapnProto,
}
