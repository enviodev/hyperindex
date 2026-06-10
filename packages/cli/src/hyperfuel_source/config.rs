use napi_derive::napi;

/// Configuration for the HyperFuel client.
#[napi(object)]
#[derive(Default, Clone)]
pub struct ClientConfig {
    pub url: String,
    pub bearer_token: Option<String>,
}
