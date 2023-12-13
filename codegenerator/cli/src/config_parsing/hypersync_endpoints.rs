use anyhow::Context;

use super::{
    chain_helpers::{Network, SupportedNetwork},
    human_config,
};

pub fn network_to_skar_url(network: &SupportedNetwork) -> String {
    match network {
        SupportedNetwork::EthereumMainnet => "https://eth.hypersync.xyz".to_string(),
        SupportedNetwork::Polygon => "https://polygon.hypersync.xyz".to_string(),
        SupportedNetwork::Gnosis => "https://gnosis.hypersync.xyz".to_string(),
        SupportedNetwork::Bsc => "https://bsc.hypersync.xyz".to_string(),
        SupportedNetwork::Goerli => "https://goerli.hypersync.xyz".to_string(),
        SupportedNetwork::Optimism => "https://optimism.hypersync.xyz".to_string(),
        SupportedNetwork::ArbitrumOne => "https://arbitrum.hypersync.xyz".to_string(),
        SupportedNetwork::Linea => "https://linea.hypersync.xyz".to_string(),
        SupportedNetwork::Sepolia => "https://sepolia.hypersync.xyz".to_string(),
        SupportedNetwork::Base => "https://base.hypersync.xyz".to_string(),
        SupportedNetwork::Scroll => "https://scroll.hypersync.xyz".to_string(),
        SupportedNetwork::Metis => "https://metis.hypersync.xyz".to_string(),
        SupportedNetwork::TaikoJolnr => "https://taiko-jolnr.hypersync.xyz".to_string(),
        SupportedNetwork::Manta => "https://manta.hypersync.xyz".to_string(),
        SupportedNetwork::PolygonZkevm => "https://polygon-zkevm.hypersync.xyz".to_string(),
        SupportedNetwork::Kroma => "https://kroma.hypersync.xyz".to_string(),
        SupportedNetwork::Celo => "https://celo.hypersync.xyz".to_string(),
        SupportedNetwork::Avalanche => "https://avalanche.hypersync.xyz".to_string(),
        SupportedNetwork::Boba => "https://avalanche.hypersync.xyz".to_string(),
        SupportedNetwork::ZksyncEra => "https://avalanche.hypersync.xyz".to_string(),
        SupportedNetwork::Moonbeam => "https://avalanche.hypersync.xyz".to_string(),
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

    let endpoint = human_config::HypersyncConfig {
        endpoint_url: network_to_skar_url(&network),
    };

    Ok(endpoint)
}

#[cfg(test)]
mod test {

    use crate::config_parsing::hypersync_endpoints::get_default_hypersync_endpoint;

    use super::SupportedNetwork;
    use strum::IntoEnumIterator;

    #[test]
    fn all_supported_chain_ids_return_a_hypersync_endpoint() {
        for network in SupportedNetwork::iter() {
            let _ = get_default_hypersync_endpoint(network as u64).unwrap();
        }
    }
}
