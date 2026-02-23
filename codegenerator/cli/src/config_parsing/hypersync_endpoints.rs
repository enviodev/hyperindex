use anyhow::Context;

use super::chain_helpers::{HypersyncNetwork, Network};

pub fn network_to_hypersync_url(network: &HypersyncNetwork) -> String {
    format!("https://{}.hypersync.xyz", *network as u64)
}

pub fn get_default_hypersync_endpoint(chain_id: u64) -> anyhow::Result<String> {
    let network_name = Network::from_network_id(chain_id)
        .context(format!("Getting network name from id ({})", chain_id))?;

    let network = HypersyncNetwork::try_from(network_name).context(format!(
        "Unsupported network (name: {}, id: {}) provided for hypersync",
        network_name, chain_id
    ))?;

    Ok(network_to_hypersync_url(&network))
}

#[cfg(test)]
mod test {

    use crate::config_parsing::hypersync_endpoints::get_default_hypersync_endpoint;

    use super::HypersyncNetwork;
    use strum::IntoEnumIterator;

    #[test]
    fn all_supported_chain_ids_return_a_hypersync_endpoint() {
        for network in HypersyncNetwork::iter() {
            let _ = get_default_hypersync_endpoint(network as u64).unwrap();
        }
    }
}

/// Integration tests that require network access.
/// Run with: cargo test --features integration_tests
#[cfg(test)]
#[cfg(feature = "integration_tests")]
mod integration_tests {
    use super::{network_to_hypersync_url, HypersyncNetwork};
    use strum::IntoEnumIterator;

    async fn fetch_hypersync_health(hypersync_endpoint: &str) -> anyhow::Result<bool> {
        let client = reqwest::Client::new();
        let url = format!("{hypersync_endpoint}/height");
        let response = client.get(&url).send().await?;
        Ok(response.status().is_success())
    }

    #[tokio::test]
    async fn all_supported_endpoints_are_healthy() {
        for network in HypersyncNetwork::iter() {
            let url = network_to_hypersync_url(&network);
            match fetch_hypersync_health(&url).await {
                Ok(is_healthy) => {
                    assert!(
                        is_healthy,
                        "Endpoint for {} is not healthy, but was expected to be.",
                        url
                    );
                }
                Err(e) => {
                    panic!("Failed to fetch health for {}: {:?}", url, e);
                }
            }
        }
    }
}
