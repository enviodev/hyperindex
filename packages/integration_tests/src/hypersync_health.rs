#[cfg(test)]
#[cfg(feature = "integration_tests")]
mod tests {
    use reqwest;

    use strum::IntoEnumIterator;

    pub enum EndpointHealth {
        Healthy,
        Unhealthy(String),
    }

    pub async fn fetch_hypersync_health(
        hypersync_endpoint: &str,
    ) -> anyhow::Result<EndpointHealth> {
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

    #[tokio::test]
    async fn all_supported_endpoints_are_healthy() {
        // TODO: implement a 'chain_id' method in hypersync, and test that the chain_id is correct too.
        for network in envio::config_parsing::chain_helpers::HypersyncNetwork::iter() {
            let rpc_url = envio::config_parsing::hypersync_endpoints::network_to_skar_url(&network);
            match fetch_hypersync_health(&rpc_url).await {
                Ok(is_healthy) => {
                    // Assert that the endpoint health is Healthy
                    assert!(
                        matches!(is_healthy, EndpointHealth::Healthy),
                        "Endpoint for {} is not healthy, but was expected to be.",
                        rpc_url
                    );
                }
                Err(e) => {
                    println!("Error fetching health for {}: {:?}", rpc_url, e); // Print error details
                    panic!("Failed to fetch health for {}: {:?}", rpc_url, e); // Panic with error details
                }
            }
        }
    }
}
