use anyhow::Context;

use super::{
    chain_helpers::{HypersyncNetwork, Network},
    human_config,
};

pub fn network_to_skar_url(network: &HypersyncNetwork) -> String {
    match network {
        HypersyncNetwork::EthereumMainnet => "https://eth.hypersync.xyz".to_string(),
        HypersyncNetwork::Polygon => "https://polygon.hypersync.xyz".to_string(),
        HypersyncNetwork::Gnosis => "https://gnosis.hypersync.xyz".to_string(),
        HypersyncNetwork::Bsc => "https://bsc.hypersync.xyz".to_string(),
        HypersyncNetwork::Goerli => "https://goerli.hypersync.xyz".to_string(),
        HypersyncNetwork::Optimism => "https://optimism.hypersync.xyz".to_string(),
        HypersyncNetwork::ArbitrumOne => "https://arbitrum.hypersync.xyz".to_string(),
        HypersyncNetwork::Linea => "https://linea.hypersync.xyz".to_string(),
        HypersyncNetwork::Sepolia => "https://sepolia.hypersync.xyz".to_string(),
        HypersyncNetwork::Base => "https://base.hypersync.xyz".to_string(),
        HypersyncNetwork::Scroll => "https://scroll.hypersync.xyz".to_string(),
        HypersyncNetwork::Metis => "https://metis.hypersync.xyz".to_string(),
        HypersyncNetwork::TaikoJolnr => "https://taiko-jolnr.hypersync.xyz".to_string(),
        HypersyncNetwork::Manta => "https://manta.hypersync.xyz".to_string(),
        HypersyncNetwork::PolygonZkevm => "https://polygon-zkevm.hypersync.xyz".to_string(),
        HypersyncNetwork::Kroma => "https://kroma.hypersync.xyz".to_string(),
        HypersyncNetwork::Celo => "https://celo.hypersync.xyz".to_string(),
        HypersyncNetwork::Avalanche => "https://avalanche.hypersync.xyz".to_string(),
        HypersyncNetwork::Boba => "https://boba.hypersync.xyz".to_string(),
        HypersyncNetwork::ZksyncEra => "https://zksync.hypersync.xyz".to_string(),
        HypersyncNetwork::Moonbeam => "https://moonbeam.hypersync.xyz".to_string(),
        HypersyncNetwork::Lukso => "https://lukso.hypersync.xyz".to_string(),
        HypersyncNetwork::Holesky => "https://holesky.hypersync.xyz".to_string(),
        HypersyncNetwork::GnosisChiado => "https://gnosis-chiado.hypersync.xyz".to_string(),
        HypersyncNetwork::OkbcTestnet => "https://okbc-testnet.hypersync.xyz".to_string(),
    }
}

pub fn get_default_hypersync_endpoint(
    chain_id: u64,
) -> anyhow::Result<human_config::HypersyncConfig> {
    let network_name = Network::from_network_id(chain_id)
        .context(format!("Getting network name from id ({})", chain_id))?;

    let network = HypersyncNetwork::try_from(network_name).context(format!(
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

    use super::HypersyncNetwork;
    use strum::IntoEnumIterator;

    #[test]
    fn all_supported_chain_ids_return_a_hypersync_endpoint() {
        for network in HypersyncNetwork::iter() {
            let _ = get_default_hypersync_endpoint(network as u64).unwrap();
        }
    }
}
