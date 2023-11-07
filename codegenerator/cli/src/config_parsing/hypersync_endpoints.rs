use anyhow::{anyhow, Context};

use crate::service_health::{self, EndpointHealth};

use super::chain_helpers::{EthArchiveNetwork, Network, SkarNetwork, SupportedNetwork};

enum HyperSyncNetwork {
    Skar(SkarNetwork),
    EthArchive(EthArchiveNetwork),
}

fn get_hypersync_network_from_supported(
    network: &SupportedNetwork,
) -> anyhow::Result<HyperSyncNetwork> {
    let network_name = Network::from(network.clone());
    match SkarNetwork::try_from(network_name.clone()) {
        Ok(n) => Ok(HyperSyncNetwork::Skar(n)),
        Err(_) => match EthArchiveNetwork::try_from(network_name) {
            Ok(n) => Ok(HyperSyncNetwork::EthArchive(n)),
            Err(_) => Err(anyhow!(
                "Unexpected! Supported network could not map to hypersync network"
            )),
        },
    }
}

pub fn network_to_eth_archive_url(network: &EthArchiveNetwork) -> String {
    match network {
        EthArchiveNetwork::Polygon => "http://46.4.5.110:77".to_string(),
        EthArchiveNetwork::ArbitrumOne => "http://46.4.5.110:75".to_string(),
        EthArchiveNetwork::Bsc => "http://46.4.5.110:73".to_string(),
        EthArchiveNetwork::Avalanche => "http://46.4.5.110:72".to_string(),
        EthArchiveNetwork::Optimism => "http://46.4.5.110:74".to_string(),
        EthArchiveNetwork::BaseTestnet => "http://46.4.5.110:78".to_string(),
        EthArchiveNetwork::Linea => "http://46.4.5.110:76".to_string(),
    }
}

pub fn network_to_skar_url(network: &SkarNetwork) -> String {
    match network {
        SkarNetwork::EthereumMainnet => "http://eth.hypersync.bigdevenergy.link:1100".to_string(),
        SkarNetwork::Polygon => "http://polygon.hypersync.bigdevenergy.link:1101".to_string(),
        SkarNetwork::Gnosis => "http://gnosis.hypersync.bigdevenergy.link:1102".to_string(),
        SkarNetwork::Bsc => "http://bsc.hypersync.bigdevenergy.link:1103".to_string(),
        SkarNetwork::Goerli => "http://goerli.hypersync.bigdevenergy.link:1104".to_string(),
        SkarNetwork::Optimism => "http://optimism.hypersync.bigdevenergy.link:1105".to_string(),
        SkarNetwork::ArbitrumOne => "http://arbitrum.hypersync.bigdevenergy.link:1106".to_string(),
        SkarNetwork::Linea => "http://linea.hypersync.bigdevenergy.link:1107".to_string(),
        SkarNetwork::Sepolia => "http://sepolia.hypersync.bigdevenergy.link:1108".to_string(),
        SkarNetwork::Base => "http://base.hypersync.bigdevenergy.link:1109".to_string(),
    }
}

pub type Url = String;
pub enum HypersyncEndpoint {
    Skar(Url),
    EthArchive(Url),
}

impl HypersyncEndpoint {
    pub async fn check_endpoint_health(&self) -> anyhow::Result<()> {
        match self {
            HypersyncEndpoint::Skar(url) | HypersyncEndpoint::EthArchive(url) => {
                match service_health::fetch_hypersync_health(url).await? {
                    EndpointHealth::Healthy => Ok(()),
                    EndpointHealth::Unhealthy(e) => Err(anyhow!(e)),
                }
            }
        }
    }
}

pub fn get_default_hypersync_endpoint(chain_id: u64) -> anyhow::Result<HypersyncEndpoint> {
    let network_name =
        Network::from_network_id(chain_id).context("getting network name from id")?;

    let network = SupportedNetwork::try_from(network_name)
        .context("Unsupported network provided for hypersync")?;

    let hypersync_network = get_hypersync_network_from_supported(&network)
        .context("Converting supported network to hypersync network")?;

    let endpoint = match hypersync_network {
        HyperSyncNetwork::Skar(n) => HypersyncEndpoint::Skar(network_to_skar_url(&n)),
        HyperSyncNetwork::EthArchive(n) => {
            HypersyncEndpoint::EthArchive(network_to_eth_archive_url(&n))
        }
    };

    Ok(endpoint)
}

#[cfg(test)]
mod test {

    use crate::config_parsing::{
        chain_helpers::Network, hypersync_endpoints::get_default_hypersync_endpoint,
    };

    use super::{EthArchiveNetwork, SkarNetwork, SupportedNetwork};
    use strum::IntoEnumIterator;

    #[test]
    fn all_supported_chain_networks_have_a_skar_or_eth_archive_network() {
        for network in SupportedNetwork::iter() {
            let skar_url = SkarNetwork::try_from(Network::from(network.clone())).is_ok();
            let eth_archive_url =
                EthArchiveNetwork::try_from(Network::from(network.clone())).is_ok();

            assert!(
                skar_url || eth_archive_url,
                "{:?} does not have a skar or eth_archive_url",
                network
            );
        }
    }

    #[test]
    fn all_supported_chain_ids_return_a_hypersync_endpoint() {
        for network in SupportedNetwork::iter() {
            let _ = get_default_hypersync_endpoint(network as u64).unwrap();
        }
    }
}
