/// The HyperFuel client options the indexer sets.
pub(crate) struct ClientConfig {
    pub url: String,
    pub api_token: String,
    pub http_req_timeout_millis: u64,
}
