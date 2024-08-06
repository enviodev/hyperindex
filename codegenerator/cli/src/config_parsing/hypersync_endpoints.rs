use anyhow::Context;

use super::chain_helpers::{HypersyncNetwork, Network};

pub fn network_to_skar_url(network: &HypersyncNetwork) -> String {
    match network {
        HypersyncNetwork::EthereumMainnet => "https://eth.hypersync.xyz".to_string(),
        HypersyncNetwork::Polygon => "https://polygon.hypersync.xyz".to_string(),
        HypersyncNetwork::Mumbai => "https://mumbai.hypersync.xyz".to_string(),
        HypersyncNetwork::Gnosis => "https://gnosis.hypersync.xyz".to_string(),
        HypersyncNetwork::Bsc => "https://bsc.hypersync.xyz".to_string(),
        HypersyncNetwork::Goerli => "https://goerli.hypersync.xyz".to_string(),
        HypersyncNetwork::Optimism => "https://optimism.hypersync.xyz".to_string(),
        HypersyncNetwork::OptimismSepolia => "https://optimism-sepolia.hypersync.xyz".to_string(),
        HypersyncNetwork::ArbitrumOne => "https://arbitrum.hypersync.xyz".to_string(),
        HypersyncNetwork::ArbitrumSepolia => "https://arbitrum-sepolia.hypersync.xyz".to_string(),
        HypersyncNetwork::Linea => "https://linea.hypersync.xyz".to_string(),
        HypersyncNetwork::Sepolia => "https://sepolia.hypersync.xyz".to_string(),
        HypersyncNetwork::Base => "https://base.hypersync.xyz".to_string(),
        HypersyncNetwork::BaseSepolia => "https://base-sepolia.hypersync.xyz".to_string(),
        HypersyncNetwork::Scroll => "https://scroll.hypersync.xyz".to_string(),
        HypersyncNetwork::Metis => "https://metis.hypersync.xyz".to_string(),
        HypersyncNetwork::TaikoJolnr => "https://taiko-jolnr.hypersync.xyz".to_string(),
        HypersyncNetwork::Manta => "https://manta.hypersync.xyz".to_string(),
        HypersyncNetwork::PolygonZkevm => "https://polygon-zkevm.hypersync.xyz".to_string(),
        HypersyncNetwork::Kroma => "https://kroma.hypersync.xyz".to_string(),
        HypersyncNetwork::Celo => "https://celo.hypersync.xyz".to_string(),
        HypersyncNetwork::Avalanche => "https://avalanche.hypersync.xyz".to_string(),
        HypersyncNetwork::Fuji => "https://fuji.hypersync.xyz".to_string(),
        HypersyncNetwork::Boba => "https://boba.hypersync.xyz".to_string(),
        HypersyncNetwork::ZksyncEra => "https://zksync.hypersync.xyz".to_string(),
        HypersyncNetwork::Moonbeam => "https://moonbeam.hypersync.xyz".to_string(),
        HypersyncNetwork::Lukso => "https://lukso.hypersync.xyz".to_string(),
        HypersyncNetwork::Holesky => "https://holesky.hypersync.xyz".to_string(),
        HypersyncNetwork::GnosisChiado => "https://gnosis-chiado.hypersync.xyz".to_string(),
        HypersyncNetwork::XLayerTestnet => "https://x-layer-testnet.hypersync.xyz".to_string(),
        HypersyncNetwork::XLayer => "https://x-layer.hypersync.xyz".to_string(),
        HypersyncNetwork::A1Milkomeda => "https://a1-milkomeda.hypersync.xyz".to_string(),
        HypersyncNetwork::PublicGoods => "https://publicgoods.hypersync.xyz".to_string(),
        HypersyncNetwork::Zora => "https://zora.hypersync.xyz".to_string(),
        HypersyncNetwork::Fantom => "https://fantom.hypersync.xyz".to_string(),
        HypersyncNetwork::ArbitrumNova => "https://arbitrum-nova.hypersync.xyz".to_string(),
        HypersyncNetwork::Harmony => "https://harmony-shard-0.hypersync.xyz".to_string(),
        HypersyncNetwork::Aurora => "https://aurora.hypersync.xyz".to_string(),
        HypersyncNetwork::C1Milkomeda => "https://c1-milkomeda.hypersync.xyz".to_string(),
        HypersyncNetwork::Flare => "https://flare.hypersync.xyz".to_string(),
        HypersyncNetwork::Mantle => "https://mantle.hypersync.xyz".to_string(),
        HypersyncNetwork::Zeta => "https://zeta.hypersync.xyz".to_string(),
        HypersyncNetwork::Rsk => "https://rsk.hypersync.xyz".to_string(),
        HypersyncNetwork::BerachainArtio => "https://berachain-artio.hypersync.xyz".to_string(),
        HypersyncNetwork::NeonEvm => "https://neon-evm.hypersync.xyz".to_string(),
        HypersyncNetwork::ShimmerEvm => "https://shimmer-evm.hypersync.xyz".to_string(),
        HypersyncNetwork::Blast => "https://blast.hypersync.xyz".to_string(),
        HypersyncNetwork::BlastSepolia => "https://blast-sepolia.hypersync.xyz".to_string(),
        HypersyncNetwork::FhenixTestnet => "https://fhenix-testnet.hypersync.xyz".to_string(),
        HypersyncNetwork::Amoy => "https://amoy.hypersync.xyz".to_string(),
        HypersyncNetwork::Crab => "https://crab.hypersync.xyz".to_string(),
        HypersyncNetwork::Darwinia => "https://darwinia.hypersync.xyz".to_string(),
        HypersyncNetwork::Cyber => "https://cyber.hypersync.xyz".to_string(),
    }
}

pub fn get_default_hypersync_endpoint(chain_id: u64) -> anyhow::Result<String> {
    let network_name = Network::from_network_id(chain_id)
        .context(format!("Getting network name from id ({})", chain_id))?;

    let network = HypersyncNetwork::try_from(network_name).context(format!(
        "Unsupported network (name: {}, id: {}) provided for hypersync",
        network_name, chain_id
    ))?;

    Ok(network_to_skar_url(&network))
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
