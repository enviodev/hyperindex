use napi_derive::napi;

/// Configuration for the hypersync client.
#[napi(object)]
#[derive(Default, Clone)]
pub struct ClientConfig {
    pub url: String,
    pub api_token: String,
    pub http_req_timeout_millis: Option<i64>,
    pub max_num_retries: Option<i64>,
    pub retry_backoff_ms: Option<i64>,
    pub retry_base_ms: Option<i64>,
    pub retry_ceiling_ms: Option<i64>,
    pub enable_checksum_addresses: Option<bool>,
    pub serialization_format: Option<SerializationFormat>,
    pub enable_query_caching: Option<bool>,
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
            max_num_retries: config
                .max_num_retries
                .filter(|v| *v >= 0)
                .map_or(Cfg::default_max_num_retries(), |v| v as usize),
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
            proactive_rate_limit_sleep: Cfg::default_proactive_rate_limit_sleep(),
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
