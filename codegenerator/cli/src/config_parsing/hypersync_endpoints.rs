use anyhow::{anyhow, Context};

use super::{
    chain_helpers::{Network, SkarNetwork, SupportedNetwork},
    human_config,
};

fn get_hypersync_network_from_supported(network: &SupportedNetwork) -> anyhow::Result<SkarNetwork> {
    let network_name = Network::from(network.clone());
    match SkarNetwork::try_from(network_name.clone()) {
        Ok(n) => Ok(n),
        Err(_) => Err(anyhow!(
            "Unexpected! Supported network could not map to hypersync network"
        )),
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
        SkarNetwork::TaikoJolnr => "https://taiko-jolnr.hypersync.xyz".to_string(),
        SkarNetwork::Manta => "https://manta.hypersync.xyz".to_string(),
        SkarNetwork::PolygonZkevm => "https://polygon-zkevm.hypersync.xyz".to_string(),
        SkarNetwork::Kroma => "https://kroma.hypersync.xyz".to_string(),
        SkarNetwork::Celo => "https://celo.hypersync.xyz".to_string(),
        SkarNetwork::Avalanche => "https://avalanche.hypersync.xyz".to_string(),
        SkarNetwork::Boba => "https://avalanche.hypersync.xyz".to_string(),
        SkarNetwork::ZksyncEra => "https://avalanche.hypersync.xyz".to_string(),
        SkarNetwork::Moonbeam => "https://avalanche.hypersync.xyz".to_string(),
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

    let endpoint = human_config::HypersyncConfig {
        endpoint_url: network_to_skar_url(&hypersync_network),
        worker_type: human_config::HypersyncWorkerType::Skar,
    };

    Ok(endpoint)
}

#[cfg(test)]
mod test {

    use crate::config_parsing::{
        chain_helpers::Network, hypersync_endpoints::get_default_hypersync_endpoint,
    };

    use super::{SkarNetwork, SupportedNetwork};
    use strum::IntoEnumIterator;

    #[test]
    fn all_supported_chain_networks_have_a_skar_network() {
        for network in SupportedNetwork::iter() {
            let skar_url = SkarNetwork::try_from(Network::from(network.clone())).is_ok();

            assert!(skar_url, "{:?} does not have a skar", network);
        }
    }

    #[test]
    fn all_supported_chain_ids_return_a_hypersync_endpoint() {
        for network in SupportedNetwork::iter() {
            let _ = get_default_hypersync_endpoint(network as u64).unwrap();
        }
    }
}
