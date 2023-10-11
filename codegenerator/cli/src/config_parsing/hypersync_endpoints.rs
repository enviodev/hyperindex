use anyhow::{anyhow, Context};
use strum_macros::EnumIter;

use crate::service_health::{self, EndpointHealth};

#[derive(Debug, EnumIter, PartialEq, Clone)]
pub enum SupportedNetwork {
    EthereumMainnet,
    Polygon,
    ArbitrumOne,
    Base,
    BinanceChain,
    AvalancheCChain,
    Optimism,
    Linea,
    EthereumGoerliTestnet,
    Gnosis,
    // EthereumSepoliaTestnet,
    // PolygonMumbaiTestnet,
    // ArbitrumNova,
    // ArbitrumGoerli,
    // BaseGoerli,
    // BinanceChainTestnet,
    // Fantom,
    // Moonbeam,
    // Moonriver,
    // Moonbase,
    // Astar,
    // ScrollAlphaTestnet,
    // ZkSync,
    // ZkSyncTestnet,
    // SKALECalypso,
    // SKALECalypsoStaging,
    // SKALENebula,
    // SKALENebulaStaging,
    // BOBAEthereum,
    // BOBAMoonbeam,
    // MantleTestnet,
    // Exosama,
}

pub fn chain_id_to_network(chain_id: &i32) -> anyhow::Result<SupportedNetwork> {
    match chain_id {
        1 => Ok(SupportedNetwork::EthereumMainnet),
        137 => Ok(SupportedNetwork::Polygon),
        42161 => Ok(SupportedNetwork::ArbitrumOne),
        84531 => Ok(SupportedNetwork::Base),
        56 => Ok(SupportedNetwork::BinanceChain),
        43114 => Ok(SupportedNetwork::AvalancheCChain),
        10 => Ok(SupportedNetwork::Optimism),
        59144 => Ok(SupportedNetwork::Linea),
        5 => Ok(SupportedNetwork::EthereumGoerliTestnet),
        100 => Ok(SupportedNetwork::Gnosis),
        // 11155111 => Ok(SupportedNetwork::EthereumSepoliaTestnet),
        // 80001 => Ok(SupportedNetwork::PolygonMumbaiTestnet),
        // 42170 => Ok(SupportedNetwork::ArbitrumNova),
        // 421613 => Ok(SupportedNetwork::ArbitrumGoerli),
        // 8453 => Ok(SupportedNetwork::BaseGoerli),
        // 97 => Ok(SupportedNetwork::BinanceChainTestnet),
        // 250 => Ok(SupportedNetwork::Fantom),
        // 1284 => Ok(SupportedNetwork::Moonbeam),
        // 1285 => Ok(SupportedNetwork::Moonriver),
        // 1287 => Ok(SupportedNetwork::Moonbase),
        // 592 => Ok(SupportedNetwork::Astar),
        // 534353 => Ok(SupportedNetwork::ScrollAlphaTestnet),
        // 324 => Ok(SupportedNetwork::ZkSync),
        // 280 => Ok(SupportedNetwork::ZkSyncTestnet),
        // 1564830818 => Ok(SupportedNetwork::SKALECalypso),
        // 344106930 => Ok(SupportedNetwork::SKALECalypsoStaging),
        // 1482601649 => Ok(SupportedNetwork::SKALENebula),
        // 503129905 => Ok(SupportedNetwork::SKALENebulaStaging),
        // 288 => Ok(SupportedNetwork::BOBAEthereum),
        // 1294 => Ok(SupportedNetwork::BOBAMoonbeam),
        // 5001 => Ok(SupportedNetwork::MantleTestnet),
        // 2109 => Ok(SupportedNetwork::Exosama),
        id => Err(anyhow!("Chain Id {id} is not supported by our servers")),
    }
}

pub fn network_to_eth_archive_url(network: &SupportedNetwork) -> Option<String> {
    match network {
        SupportedNetwork::Polygon => Some("http://46.4.5.110:77".to_string()),
        SupportedNetwork::ArbitrumOne => Some("http://46.4.5.110:75".to_string()),
        SupportedNetwork::BinanceChain => Some("http://46.4.5.110:73".to_string()),
        SupportedNetwork::AvalancheCChain => Some("http://46.4.5.110:72".to_string()),
        SupportedNetwork::Optimism => Some("http://46.4.5.110:74".to_string()),
        SupportedNetwork::Base => Some("http://46.4.5.110:78".to_string()),
        SupportedNetwork::Linea => Some("http://46.4.5.110:76".to_string()),
        _ => None,
        // SupportedNetwork::EthereumMainnet => Some("https://eth.archive.subsquid.io".to_string()),
        // SupportedNetwork::EthereumGoerliTestnet => Some("https://goerli.archive.subsquid.io".to_string()),
        // SupportedNetwork::EthereumSepoliaTestnet => Some("https://sepolia.archive.subsquid.io".to_string()),
        // SupportedNetwork::PolygonMumbaiTestnet => Some("https://polygon-mumbai.archive.subsquid.io".to_string()),
        // SupportedNetwork::ArbitrumNova => Some("https://arbitrum-nova.archive.subsquid.io".to_string()),
        // SupportedNetwork::ArbitrumGoerli => Some("https://arbitrum-goerli.archive.subsquid.io".to_string()),
        // SupportedNetwork::BaseGoerli => Some("https://base-goerli.archive.subsquid.io".to_string()),
        // SupportedNetwork::BinanceChainTestnet => Some("https://binance-testnet.archive.subsquid.io".to_string()),
        // SupportedNetwork::Fantom => Some("https://fantom.archive.subsquid.io".to_string()),
        // SupportedNetwork::Moonbeam => Some("https://moonbeam-evm.archive.subsquid.io".to_string()),
        // SupportedNetwork::Moonriver => Some("https://moonriver-evm.archive.subsquid.io".to_string()),
        // SupportedNetwork::Moonbase => Some("https://moonbase-evm.archive.subsquid.io".to_string()),
        // SupportedNetwork::Astar => Some("https://astar-evm.archive.subsquid.io".to_string()),
        // SupportedNetwork::ScrollAlphaTestnet => Some("https://scroll-alpha-testnet.archive.subsquid.io".to_string()),
        // SupportedNetwork::ZkSync => Some("https://zksync.archive.subsquid.io".to_string()),
        // SupportedNetwork::ZkSyncTestnet => Some("https://zksync-testnet.archive.subsquid.io".to_string()),
        // SupportedNetwork::SKALECalypso => Some("https://skale-calypso.archive.subsquid.io".to_string()),
        // SupportedNetwork::SKALECalypsoStaging => Some("https://skale-calypso-staging.archive.subsquid.io".to_string()),
        // SupportedNetwork::SKALENebula => Some("https://skale-nebula.archive.subsquid.io".to_string()),
        // SupportedNetwork::SKALENebulaStaging => Some("https://skale-nebula-staging.archive.subsquid.io".to_string()),
        // SupportedNetwork::BOBAEthereum => Some("https://boba-eth.archive.subsquid.io".to_string()),
        // SupportedNetwork::BOBAMoonbeam => Some("https://boba-moonbeam.archive.subsquid.io".to_string()),
        // SupportedNetwork::MantleTestnet => Some("https://mantle-testnet.archive.subsquid.io".to_string()),
        // SupportedNetwork::Exosama => Some("https://exosama.archive.subsquid.io".to_string()),
    }
}

pub fn network_to_skar_url(network: &SupportedNetwork) -> Option<String> {
    match network {
        SupportedNetwork::EthereumMainnet => Some("http://eth.hypersync.bigdevenergy.link:1100".to_string()),
        SupportedNetwork::Polygon => Some("http://polygon.hypersync.bigdevenergy.link:1101".to_string()),
        SupportedNetwork::Gnosis => Some("http://gnosis.hypersync.bigdevenergy.link:1102".to_string()),
        SupportedNetwork::EthereumGoerliTestnet => Some("http://goerli.hypersync.bigdevenergy.link:1104".to_string()),
        _ => None

        // SupportedNetwork::Polygon => Some("http://91.216.245.118:2151".to_string()),
        // SupportedNetwork::EthereumSepoliaTestnet => "https://sepolia.archive.subsquid.io",
        // SupportedNetwork::PolygonMumbaiTestnet => "https://polygon-mumbai.archive.subsquid.io",
        // SupportedNetwork::ArbitrumOne => "https://arbitrum.archive.subsquid.io",
        // SupportedNetwork::ArbitrumNova => "https://arbitrum-nova.archive.subsquid.io",
        // SupportedNetwork::ArbitrumGoerli => "https://arbitrum-goerli.archive.subsquid.io",
        // SupportedNetwork::BaseGoerli => "https://base-goerli.archive.subsquid.io",
        // SupportedNetwork::BinanceChain => "https://binance.archive.subsquid.io",
        // SupportedNetwork::BinanceChainTestnet => "https://binance-testnet.archive.subsquid.io",
        // SupportedNetwork::AvalancheCChain => "https://avalanche-c.archive.subsquid.io",
        // SupportedNetwork::Fantom => "https://fantom.archive.subsquid.io",
        // SupportedNetwork::Optimism => "https://optimism-mainnet.archive.subsquid.io",
        // SupportedNetwork::Moonbeam => "https://moonbeam-evm.archive.subsquid.io",
        // SupportedNetwork::Moonriver => "https://moonriver-evm.archive.subsquid.io",
        // SupportedNetwork::Moonbase => "https://moonbase-evm.archive.subsquid.io",
        // SupportedNetwork::Astar => "https://astar-evm.archive.subsquid.io",
        // SupportedNetwork::ScrollAlphaTestnet => "https://scroll-alpha-testnet.archive.subsquid.io",
        // SupportedNetwork::ZkSync => "https://zksync.archive.subsquid.io",
        // SupportedNetwork::ZkSyncTestnet => "https://zksync-testnet.archive.subsquid.io",
        // SupportedNetwork::SKALECalypso => "https://skale-calypso.archive.subsquid.io",
        // SupportedNetwork::SKALECalypsoStaging => {
        //     "https://skale-calypso-staging.archive.subsquid.io"
        // }
        // SupportedNetwork::SKALENebula => "https://skale-nebula.archive.subsquid.io",
        // SupportedNetwork::SKALENebulaStaging => "https://skale-nebula-staging.archive.subsquid.io",
        // SupportedNetwork::BOBAEthereum => "https://boba-eth.archive.subsquid.io",
        // SupportedNetwork::BOBAMoonbeam => "https://boba-moonbeam.archive.subsquid.io",
        // SupportedNetwork::MantleTestnet => "https://mantle-testnet.archive.subsquid.io",
        // SupportedNetwork::Exosama => "https://exosama.archive.subsquid.io",
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

pub fn get_default_hypersync_endpoint(chain_id: &i32) -> anyhow::Result<HypersyncEndpoint> {
    let network =
        chain_id_to_network(chain_id).context("Failed getting default hypersync endpoint")?;

    network_to_skar_url(&network)
        .map(|url| HypersyncEndpoint::Skar(url))
        .or_else(|| {
            network_to_eth_archive_url(&network).map(|url| HypersyncEndpoint::EthArchive(url))
        })
        .ok_or_else(|| {
            anyhow!(
                "Network {:?} {} does not have a hypersync endpiont",
                network,
                chain_id
            )
        })
}

#[cfg(test)]
mod test {

    use crate::config_parsing::hypersync_endpoints::get_default_hypersync_endpoint;

    use super::{
        chain_id_to_network, network_to_eth_archive_url, network_to_skar_url, SupportedNetwork,
    };
    use anyhow::Context;
    use strum::IntoEnumIterator;

    ///Currently only used for exhaustive testing. Can move this into the main module if needed
    ///elsewhere
    fn network_to_chain_id(network: SupportedNetwork) -> i32 {
        match network {
            SupportedNetwork::EthereumMainnet => 1,
            SupportedNetwork::Polygon => 137,
            SupportedNetwork::ArbitrumOne => 42161,
            SupportedNetwork::BinanceChain => 56,
            SupportedNetwork::AvalancheCChain => 43114,
            SupportedNetwork::Optimism => 10,
            SupportedNetwork::Base => 84531,
            SupportedNetwork::Linea => 59144,
            SupportedNetwork::EthereumGoerliTestnet => 5,
            SupportedNetwork::Gnosis => 100,
            // SupportedNetwork::EthereumSepoliaTestnet => 11155111,
            // SupportedNetwork::PolygonMumbaiTestnet => 80001,
            // SupportedNetwork::ArbitrumNova => 42170,
            // SupportedNetwork::ArbitrumGoerli => 421613,
            // SupportedNetwork::BaseGoerli => 8453,
            // SupportedNetwork::BinanceChainTestnet => 97,
            // SupportedNetwork::Fantom => 250,
            // SupportedNetwork::Moonbeam => 1284,
            // SupportedNetwork::Moonriver => 1285,
            // SupportedNetwork::Moonbase => 1287,
            // SupportedNetwork::Astar => 592,
            // SupportedNetwork::ScrollAlphaTestnet => 534353,
            // SupportedNetwork::ZkSync => 324,
            // SupportedNetwork::ZkSyncTestnet => 280,
            // SupportedNetwork::SKALECalypso => 1564830818,
            // SupportedNetwork::SKALECalypsoStaging => 344106930,
            // SupportedNetwork::SKALENebula => 1482601649,
            // SupportedNetwork::SKALENebulaStaging => 503129905,
            // SupportedNetwork::BOBAEthereum => 288,
            // SupportedNetwork::BOBAMoonbeam => 1294,
            // SupportedNetwork::MantleTestnet => 5001,
            // SupportedNetwork::Exosama => 2109,
        }
    }

    #[test]
    fn all_supported_chain_networks_have_a_chain_id_mapping() {
        for network in SupportedNetwork::iter() {
            let chain_id = network_to_chain_id(network.clone());

            let converted_network = chain_id_to_network(&chain_id)
                .context("Testing all networks have a chain id converter")
                .unwrap();

            assert_eq!(&converted_network, &network);
        }
    }

    #[test]
    fn all_supported_chain_networks_have_a_skar_or_eth_archive_url() {
        for network in SupportedNetwork::iter() {
            let skar_url = network_to_skar_url(&network).is_some();
            let eth_archive_url = network_to_eth_archive_url(&network).is_some();

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
            let chain_id = network_to_chain_id(network.clone());

            let _ = get_default_hypersync_endpoint(&chain_id).unwrap();
        }
    }
}
