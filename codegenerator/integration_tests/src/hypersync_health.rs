use reqwest;

pub enum EndpointHealth {
    Healthy,
    Unhealthy(String),
}

pub async fn fetch_hypersync_health(hypersync_endpoint: &str) -> anyhow::Result<EndpointHealth> {
    let client = reqwest::Client::new();
    let url = format!("{hypersync_endpoint}/height");
    let response = client.get(&url).send().await?;
    let is_success = response.status().is_success();

    if is_success {
        Ok(EndpointHealth::Healthy)
    } else {
        Ok(EndpointHealth::Unhealthy(format!(
            "bad response from {url}"
        )))
    }
}
