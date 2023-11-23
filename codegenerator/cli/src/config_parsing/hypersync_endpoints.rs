use anyhow::{anyhow, Context};

use super::{
    chain_helpers::{EthArchiveNetwork, Network, SkarNetwork, SupportedNetwork},
    human_config,
};

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
        EthArchiveNetwork::Avalanche => "http://46.4.5.110:72".to_string(),
        EthArchiveNetwork::BaseTestnet => "http://46.4.5.110:78".to_string(),
    }
}

pub fn network_to_skar_url(network: &SkarNetwork) -> String {
    match network {
        SkarNetwork::EthereumMainnet => "https://eth.hypersync.xyz".to_string(),
        SkarNetwork::Polygon => "https://polygon.hypersync.xyz".to_string(),
        SkarNetwork::Gnosis => "https://gnosis.hypersync.xyz".to_string(),
        SkarNetwork::Bsc => "https://bsc.hypersync.xyz".to_string(),
        SkarNetwork::Goerli => "https://goerli.hypersync.xyz".to_string(),
        SkarNetwork::Optimism => "https://optimism.hypersync.xyz".to_string(),
        SkarNetwork::ArbitrumOne => "https://arbitrum.hypersync.xyz".to_string(),
        SkarNetwork::Linea => "https://linea.hypersync.xyz".to_string(),
        SkarNetwork::Sepolia => "https://sepolia.hypersync.xyz".to_string(),
        SkarNetwork::Base => "https://base.hypersync.xyz".to_string(),
        SkarNetwork::Scroll => "https://scroll.hypersync.xyz".to_string(),
        SkarNetwork::Metis => "https://metis.hypersync.xyz".to_string(),
        SkarNetwork::TaikoJolnr => "https://taiko-jolnr.hypersync.xyz/".to_string(),
        SkarNetwork::Manta => "https://manta.hypersync.xyz/".to_string(),
        SkarNetwork::PolygonZkevm => "https://polygon-zkevm.hypersync.xyz/".to_string(),
        SkarNetwork::Kroma => "https://kroma.hypersync.xyz/".to_string(),
        SkarNetwork::Celo => "https://kroma.hypersync.xyz/".to_string(),
    }
}

pub fn get_default_hypersync_endpoint(
    chain_id: u64,
) -> anyhow::Result<human_config::HypersyncConfig> {
    let network_name = Network::from_network_id(chain_id)
        .context(format!("Getting network name from id ({})", chain_id))?;

    let network = SupportedNetwork::try_from(network_name).context(format!(
        "Unsupported network (name: {}, id: {}) provided for hypersync",
        network_name, chain_id
    ))?;

    let hypersync_network = get_hypersync_network_from_supported(&network).context(format!(
        "Converting supported network to hypersync network, chainId: {}",
        chain_id
    ))?;

    let endpoint = match hypersync_network {
        HyperSyncNetwork::Skar(n) => human_config::HypersyncConfig {
            endpoint_url: network_to_skar_url(&n),
            worker_type: human_config::HypersyncWorkerType::Skar,
        },
        HyperSyncNetwork::EthArchive(n) => human_config::HypersyncConfig {
            endpoint_url: network_to_eth_archive_url(&n),
            worker_type: human_config::HypersyncWorkerType::EthArchive,
        },
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
