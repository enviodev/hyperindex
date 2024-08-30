use std::env;

use anyhow::anyhow;
use anyhow::Context;
use clap::ValueEnum;
use ethers::etherscan;
use serde::{Deserialize, Serialize};
use strum::FromRepr;
use strum::IntoEnumIterator;
use strum_macros::{Display, EnumIter, EnumString};
use subenum::subenum;

use crate::constants::DEFAULT_CONFIRMED_BLOCK_THRESHOLD;

#[subenum(NetworkWithExplorer, HypersyncNetwork, GraphNetwork)]
#[derive(
    Clone,
    Debug,
    ValueEnum,
    Serialize,
    Deserialize,
    EnumIter,
    EnumString,
    FromRepr,
    PartialEq,
    Eq,
    Display,
    Hash,
    Copy,
)]
#[serde(rename_all = "kebab-case")]
#[strum(serialize_all = "kebab-case")]
#[repr(u64)]
pub enum Network {
    #[subenum(
        HypersyncNetwork,
        NetworkWithExplorer,
        GraphNetwork(serde(rename = "mainnet"))
    )]
    EthereumMainnet = 1,
    #[subenum(HypersyncNetwork, NetworkWithExplorer, GraphNetwork)]
    Goerli = 5,
    #[subenum(HypersyncNetwork, NetworkWithExplorer, GraphNetwork)]
    Optimism = 10,
    #[subenum(HypersyncNetwork, NetworkWithExplorer, GraphNetwork)]
    Base = 8453,
    #[subenum(HypersyncNetwork, NetworkWithExplorer)]
    // explorers:
    // https://sepolia.basescan.org/
    // https://base-sepolia.blockscout.com/
    BaseSepolia = 84532,
    #[subenum(HypersyncNetwork, NetworkWithExplorer, GraphNetwork)]
    Bsc = 56,
    #[subenum(GraphNetwork)]
    PoaSokol = 77,
    #[subenum(GraphNetwork)]
    Mumbai = 80001,
    #[subenum(HypersyncNetwork, GraphNetwork(serde(rename = "chapel")))]
    BscTestnet = 97,
    #[subenum(GraphNetwork)]
    PoaCore = 99,
    #[subenum(HypersyncNetwork, NetworkWithExplorer, GraphNetwork)]
    Gnosis = 100,
    #[subenum(GraphNetwork)]
    Fuse = 122,
    #[subenum(HypersyncNetwork, NetworkWithExplorer, GraphNetwork)]
    Fantom = 250,
    #[subenum(
        HypersyncNetwork,
        NetworkWithExplorer,
        GraphNetwork(serde(rename = "matic"))
    )]
    Polygon = 137,
    #[subenum(HypersyncNetwork)]
    // explorers:
    // https://bobascan.com/ (not etherscan)
    Boba = 288,
    #[subenum(NetworkWithExplorer, GraphNetwork)]
    OptimismGoerli = 420,
    #[subenum(HypersyncNetwork, NetworkWithExplorer)]
    // Alt-explorer:
    // https://optimism-sepolia.blockscout.com/
    OptimismSepolia = 11155420,
    #[subenum(GraphNetwork)]
    Clover = 1023,
    #[subenum(HypersyncNetwork, NetworkWithExplorer, GraphNetwork)]
    Moonbeam = 1284,
    #[subenum(GraphNetwork)]
    Moonriver = 1285,
    #[subenum(GraphNetwork)]
    Mbase = 1287,
    #[subenum(GraphNetwork)]
    FantomTestnet = 4002,
    #[subenum(HypersyncNetwork, NetworkWithExplorer, GraphNetwork)]
    ArbitrumOne = 42161,
    #[subenum(HypersyncNetwork, NetworkWithExplorer)]
    ArbitrumNova = 42170,
    #[subenum(NetworkWithExplorer, GraphNetwork)]
    ArbitrumGoerli = 421613,
    #[subenum(HypersyncNetwork, NetworkWithExplorer, GraphNetwork)]
    ArbitrumSepolia = 421614,
    #[subenum(HypersyncNetwork, GraphNetwork, NetworkWithExplorer)]
    Celo = 42220,
    #[subenum(HypersyncNetwork, GraphNetwork, NetworkWithExplorer)]
    Fuji = 43113,
    #[subenum(HypersyncNetwork, GraphNetwork, NetworkWithExplorer)]
    Avalanche = 43114,
    #[subenum(GraphNetwork)]
    CeloAlfajores = 44787,
    #[subenum(HypersyncNetwork, GraphNetwork)]
    // Blockscout: https://explorer.aurora.dev/
    Aurora = 1313161554,
    #[subenum(GraphNetwork)]
    AuroraTestnet = 1313161555,
    #[subenum(HypersyncNetwork)]
    // Explorers:
    // https://explorer.harmony.one/
    // https://getblock.io/explorers/harmony/
    Harmony = 1666600000, // shard 0
    #[subenum(GraphNetwork(serde(rename = "base-testnet")))]
    BaseGoerli = 84531,
    #[subenum(HypersyncNetwork, GraphNetwork)]
    ZksyncEra = 324,
    #[subenum(HypersyncNetwork, NetworkWithExplorer, GraphNetwork)]
    Sepolia = 11155111,
    #[subenum(HypersyncNetwork, NetworkWithExplorer)]
    Linea = 59144,
    #[subenum(GraphNetwork)]
    Rinkeby = 4,
    #[subenum(GraphNetwork)]
    ZksyncEraTestnet = 280,
    #[subenum(GraphNetwork)]
    PolygonZkevmTestnet = 1422,
    #[subenum(GraphNetwork, HypersyncNetwork, NetworkWithExplorer)]
    PolygonZkevm = 1101,
    #[subenum(GraphNetwork)]
    ScrollSepolia = 534351,
    #[subenum(GraphNetwork, HypersyncNetwork, NetworkWithExplorer)]
    Scroll = 534352,
    #[subenum(HypersyncNetwork)]
    Metis = 1088,
    #[subenum(HypersyncNetwork)]
    // Explorers:
    // blockscout: https://pacific-explorer.manta.network/
    // w3w.ai: https://manta.socialscan.io/
    Manta = 169,
    #[subenum(HypersyncNetwork, NetworkWithExplorer)]
    Kroma = 255,
    #[subenum(HypersyncNetwork)]
    // Explorers:
    // https://explorer.execution.mainnet.lukso.network/
    // https://blockscout.com/lukso/l14
    Lukso = 42,
    #[subenum(HypersyncNetwork)]
    // Explorers:
    // https://www.oklink.com/x1-test
    XLayerTestnet = 195,
    #[subenum(HypersyncNetwork)]
    // Explorers:
    // https://www.oklink.com/xlayer
    XLayer = 196,
    #[subenum(HypersyncNetwork, NetworkWithExplorer)]
    Holesky = 17000,
    #[subenum(HypersyncNetwork)]
    // Explorers:
    // https://gnosis-chiado.blockscout.com/
    GnosisChiado = 10200,
    #[subenum(HypersyncNetwork)]
    // Explorers:
    // https://explorer.zora.energy/
    Zora = 7777777,
    #[subenum(HypersyncNetwork)]
    // Explorers:
    // Blockscout: https://explorer-mainnet-cardano-evm.c1.milkomeda.com/
    C1Milkomeda = 2001,
    #[subenum(HypersyncNetwork)]
    // Explorers:
    // Blockscout: https://flare-explorer.flare.network/
    // Routescan: https://flarescan.com/
    Flare = 14,
    #[subenum(HypersyncNetwork)]
    // Explorers:
    // https://explorer.mantle.xyz/
    // Routescan: https://mantlescan.info/
    Mantle = 5000,
    #[subenum(HypersyncNetwork)]
    // Explorers:
    // https://explorer.zetachain.com/
    // https://zetachain.explorers.guru/
    Zeta = 7000,
    #[subenum(HypersyncNetwork)]
    // Explorers:
    // https://neonscan.org/
    // https://neon.blockscout.com/
    NeonEvm = 245022934,
    #[subenum(HypersyncNetwork)]
    // Explorers:
    // https://explorer.rsk.co/
    // https://rootstock.blockscout.com/
    Rsk = 30,
    #[subenum(HypersyncNetwork)]
    // Explorers:
    // https://explorer.evm.shimmer.network/
    ShimmerEvm = 148,
    #[subenum(HypersyncNetwork, NetworkWithExplorer)]
    Blast = 81457,
    #[subenum(HypersyncNetwork, NetworkWithExplorer)]
    BlastSepolia = 168587773,
    #[subenum(HypersyncNetwork)]
    // Explorers:
    // https://explorer.testnet.fhenix.zone/ (blockscout)
    FhenixTestnet = 42069,
    #[subenum(HypersyncNetwork, NetworkWithExplorer)]
    Amoy = 80002,
    #[subenum(HypersyncNetwork)]
    // Explorers:
    // https://crab.subscan.io/
    Crab = 44,
    #[subenum(HypersyncNetwork)]
    // Explorers:
    // https://darwinia.subscan.io/
    Darwinia = 46,
    #[subenum(HypersyncNetwork)]
    // Explorers:
    // NOTE: this does have contract verification and an api to get verified contracts, but this
    // breaks with the current setup. TODO: get non-etherscan contract verification working.
    // https://cyber.socialscan.io/
    Cyber = 7560,
    // #[subenum(HypersyncNetwork)]
    // // Explorers:
    // // https://explorer.degen.tips/
    // Degen = 666666666,
    #[subenum(HypersyncNetwork)]
    Chiliz = 8888,
    #[subenum(HypersyncNetwork)]
    IncoGentryTestnet = 9090,
    #[subenum(HypersyncNetwork)]
    Zircuit = 48900,
    #[subenum(HypersyncNetwork)]
    MevCommit = 17864,
    #[subenum(HypersyncNetwork)]
    GaladrielDevnet = 696969,
    #[subenum(HypersyncNetwork)]
    SophonTestnet = 531050104,
    #[subenum(HypersyncNetwork)]
    KakarotSepolia = 1802203764,
    #[subenum(HypersyncNetwork)]
    BerachainBartio = 80084,
    // Still syncing
    // #[subenum(HypersyncNetwork)]
    // Saakuru = 7225878,
}

impl Network {
    pub fn get_network_id(&self) -> u64 {
        self.clone() as u64
    }

    pub fn from_network_id(id: u64) -> anyhow::Result<Self> {
        Network::from_repr(id)
            .ok_or_else(|| anyhow!("Failed converting network_id {} to network name", id))
    }

    //TODO: research a sufficient threshold for all chain (some should be 0)
    pub fn get_confirmed_block_threshold(&self) -> i32 {
        match self {
            //Reorgs do not happen on these networks
            Network::OptimismGoerli
            | Network::OptimismSepolia
            | Network::Optimism
            | Network::ArbitrumOne
            | Network::ArbitrumNova
            | Network::ArbitrumGoerli
            | Network::ArbitrumSepolia => 0,
            //TODO: research a sufficient threshold for all chains
            Network::Base
            | Network::Mumbai
            | Network::BaseSepolia
            | Network::Bsc
            | Network::Goerli
            | Network::Gnosis
            | Network::Fantom
            | Network::Polygon
            | Network::Boba
            | Network::Celo
            | Network::Aurora
            | Network::AuroraTestnet
            | Network::Harmony
            | Network::EthereumMainnet
            | Network::PoaSokol
            | Network::BscTestnet
            | Network::PoaCore
            | Network::Fuse
            | Network::Clover
            | Network::Moonbeam
            | Network::Moonriver
            | Network::Mbase
            | Network::FantomTestnet
            | Network::Fuji
            | Network::Avalanche
            | Network::CeloAlfajores
            | Network::BaseGoerli
            | Network::ZksyncEra
            | Network::Sepolia
            | Network::Linea
            | Network::Rinkeby
            | Network::ZksyncEraTestnet
            | Network::PolygonZkevmTestnet
            | Network::PolygonZkevm
            | Network::ScrollSepolia
            | Network::Scroll
            | Network::Metis
            | Network::Manta
            | Network::Kroma
            | Network::Lukso
            | Network::XLayerTestnet
            | Network::XLayer
            | Network::Holesky
            | Network::GnosisChiado
            | Network::Zora
            | Network::C1Milkomeda
            | Network::Flare
            | Network::Mantle
            | Network::Zeta
            | Network::NeonEvm
            | Network::Rsk
            | Network::ShimmerEvm
            | Network::Blast
            | Network::BlastSepolia
            | Network::FhenixTestnet
            | Network::Amoy
            | Network::Crab
            | Network::Darwinia
            | Network::Cyber
            | Network::Chiliz
            | Network::IncoGentryTestnet
            | Network::Zircuit
            | Network::MevCommit
            | Network::GaladrielDevnet
            | Network::SophonTestnet
            | Network::KakarotSepolia
            | Network::BerachainBartio => DEFAULT_CONFIRMED_BLOCK_THRESHOLD,
        }
    }
}

impl HypersyncNetwork {
    // This is a custom iterator that returns all the HypersyncNetwork enums that is made public accross crates (for convenience)
    pub fn iter_hypersync_networks() -> impl Iterator<Item = HypersyncNetwork> {
        HypersyncNetwork::iter()
    }
}

pub enum BlockExplorerApi {
    DefaultEthers,
    Custom {
        //eg. "https://gnosisscan.io/"
        base_url: String,
        //eg. "https://api.gnosisscan.io/api/"
        api_url: String,
    },
}

impl BlockExplorerApi {
    fn custom(base_url: &str, api_url: &str) -> Self {
        let base_url = format!("https://{}/", base_url);
        let api_url = format!("https://{}/api/", api_url);
        Self::Custom { base_url, api_url }
    }
}

impl NetworkWithExplorer {
    pub fn get_block_explorer_api(&self) -> BlockExplorerApi {
        match self {
            NetworkWithExplorer::Celo => BlockExplorerApi::custom("celoscan.io", "api.celoscan.io"),
            NetworkWithExplorer::Gnosis => {
                BlockExplorerApi::custom("gnosisscan.io", "api.gnosisscan.io")
            }
            NetworkWithExplorer::Holesky => {
                BlockExplorerApi::custom("holesky.etherscan.io", "api-holesky.etherscan.io")
            }
            NetworkWithExplorer::Scroll => {
                BlockExplorerApi::custom("scrollscan.com", "api.scrollscan.com")
            }
            NetworkWithExplorer::ArbitrumSepolia => {
                BlockExplorerApi::custom("sepolia.arbiscan.io", "api-sepolia.arbiscan.io")
            }
            NetworkWithExplorer::Kroma => {
                BlockExplorerApi::custom("kromascan.com", "api.kromascan.com")
            }
            NetworkWithExplorer::BaseSepolia => {
                BlockExplorerApi::custom("sepolia.basescan.org", "api-sepolia.basescan.org")
            }
            NetworkWithExplorer::OptimismSepolia => BlockExplorerApi::custom(
                "sepolia-optimistic.etherscan.io",
                "api-sepolia-optimistic.etherscan.io",
            ),
            NetworkWithExplorer::Blast => {
                BlockExplorerApi::custom("blastscan.io", "api.blastscan.io")
            }
            NetworkWithExplorer::BlastSepolia => {
                BlockExplorerApi::custom("blastscan.io", "api-testnet.blastscan.io")
            }
            NetworkWithExplorer::Avalanche => BlockExplorerApi::custom(
                "avalanche.routescan.io",
                "api.routescan.io/v2/network/mainnet/evm/43114/etherscan",
            ),
            NetworkWithExplorer::Fuji => BlockExplorerApi::custom(
                "avalanche.testnet.routescan.io",
                "api.routescan.io/v2/network/testnet/evm/43113/etherscan",
            ),
            NetworkWithExplorer::Amoy => {
                BlockExplorerApi::custom("amoy.polygonscan.com", "api-amoy.polygonscan.com")
            }
            //// Having issues getting blockscout to work.
            // NetworkWithExplorer::Aurora => BlockExplorerApi::custom(
            //     "explorer.mainnet.aurora.dev",
            //     "explorer.mainnet.aurora.dev/api",
            //      /// also tried some variations: explorer.mainnet.aurora.dev/api/v2
            // ),
            // NetworkWithExplorer::Lukso => BlockExplorerApi::custom(
            //     "explorer.execution.mainnet.lukso.network",
            //     "explorer.execution.mainnet.lukso.network/api",
            // /// Also tried some variations:
            //   blockscout.com/lukso/l14
            //
            // ),
            _ => BlockExplorerApi::DefaultEthers,
        }
    }

    pub fn get_env_token_name(&self) -> String {
        let name = format!("{:?}", self); // Converts enum variant to string
        let name = name.replace("NetworkWithExplorer::", ""); // Remove the enum type prefix
        let name = name.replace("-", "_"); // Replace hyphens with underscores
        let name = name.to_uppercase(); // Convert to uppercase
        format!("{}_VERIFIED_CONTRACT_API_TOKEN", name)
    }
}

pub fn get_etherscan_client(network: &NetworkWithExplorer) -> anyhow::Result<etherscan::Client> {
    // Try to get the API token from the environment variable
    let maybe_api_key = env::var(network.get_env_token_name());

    let client = match network.get_block_explorer_api() {
        BlockExplorerApi::DefaultEthers => {
            let chain_id = Network::from(*network).get_network_id();
            let ethers_chain = ethers::types::Chain::try_from(chain_id)
                .context("Failed converting network with explorer id to ethers chain")?;

            // The api doesn't allow not passing in an api key, but a
            // blank string is allowed
            etherscan::Client::new(ethers_chain, maybe_api_key.unwrap_or("".to_string()))
                .context("Failed creating client for network")?
        }

        BlockExplorerApi::Custom { base_url, api_url } => {
            let mut builder = etherscan::Client::builder()
                .with_url(&base_url)
                .context(format!(
                    "Failed building custom client at base url {}",
                    base_url
                ))?
                .with_api_url(&api_url)
                .context(format!(
                    "Failed building custom client at api url {}",
                    api_url
                ))?;

            if let Ok(key) = maybe_api_key {
                builder = builder.with_api_key(&key);
            }

            builder.build().context("Failed build custom client")?
        }
    };

    Ok(client)
}

pub fn get_confirmed_block_threshold_from_id(id: u64) -> i32 {
    Network::from_network_id(id).map_or(DEFAULT_CONFIRMED_BLOCK_THRESHOLD, |n| {
        n.get_confirmed_block_threshold()
    })
}

#[cfg(test)]
mod test {

    use super::{get_etherscan_client, GraphNetwork, HypersyncNetwork, NetworkWithExplorer};
    use crate::config_parsing::chain_helpers::Network;
    use pretty_assertions::assert_eq;
    use serde::Deserialize;
    use strum::IntoEnumIterator;

    #[test]
    fn all_networks_with_explorer_can_get_etherscan_client() {
        for network in NetworkWithExplorer::iter() {
            get_etherscan_client(&network).unwrap();
        }
    }

    #[test]
    fn network_deserialize() {
        let names = r#"["ethereum-mainnet", "polygon"]"#;
        let names_des: Vec<HypersyncNetwork> = serde_json::from_str(names).unwrap();
        let expected = vec![HypersyncNetwork::EthereumMainnet, HypersyncNetwork::Polygon];
        assert_eq!(expected, names_des);
    }

    #[test]
    fn strum_serialize() {
        assert_eq!(
            "ethereum-mainnet".to_string(),
            Network::EthereumMainnet.to_string()
        );
    }

    #[test]
    fn network_deserialize_graph() {
        /*List of networks supported by graph found here:
         * https://github.com/graphprotocol/graph-tooling/blob/main/packages/cli/src/protocols/index.ts#L94-L132
         */
        let networks = r#"[
        "mainnet",
        "rinkeby",
        "goerli",
        "poa-core",
        "poa-sokol",
        "gnosis",
        "matic",
        "fantom",
        "fantom-testnet",
        "bsc",
        "chapel",
        "clover",
        "avalanche",
        "fuji",
        "celo",
        "celo-alfajores",
        "fuse",
        "moonbeam",
        "moonriver",
        "mbase",
        "arbitrum-one",
        "arbitrum-goerli",
        "arbitrum-sepolia",
        "optimism",
        "optimism-goerli",
        "aurora",
        "aurora-testnet",
        "base-testnet",
        "base",
        "zksync-era",
        "zksync-era-testnet",
        "sepolia",
        "polygon-zkevm-testnet",
        "polygon-zkevm",
        "scroll-sepolia",
        "scroll"
    ]"#;

        let supported_graph_networks = serde_json::from_str::<Vec<String>>(networks)
            .unwrap()
            .into_iter()
            .map(|s| {
                GraphNetwork::deserialize(serde_json::Value::String(s.clone()))
                    // serde_json::from_str::<GraphNetwork>(&s)
                    .expect(format!("Invalid graph network: {}", s).as_str())
                // GraphNetwork::from_str(&s).expect(format!("Invalid graph network: {}", s).as_str())
            })
            .collect::<Vec<GraphNetwork>>();

        let defined_networks = GraphNetwork::iter().collect::<Vec<_>>();

        for n in defined_networks {
            let included_in_supported_networks = supported_graph_networks
                .iter()
                .find(|&sn| &n == sn)
                .is_some();
            assert!(
                included_in_supported_networks,
                "expected {:?} to be included",
                n
            )
        }
    }

    #[test]
    fn network_api_key_name() {
        let env_token_name = NetworkWithExplorer::EthereumMainnet.get_env_token_name();
        assert_eq!(
            env_token_name,
            "ETHEREUMMAINNET_VERIFIED_CONTRACT_API_TOKEN"
        );
    }

    use tracing_subscriber;

    #[tokio::test]
    #[ignore = "Integration test that interacts with block explorer API"]
    async fn check_gnosis_get_contract_source_code() {
        tracing_subscriber::fmt::init();
        let network: NetworkWithExplorer = NetworkWithExplorer::Gnosis;
        let client = get_etherscan_client(&network).unwrap();

        client
            .contract_source_code(
                "0x4ECaBa5870353805a9F068101A40E0f32ed605C6"
                    .parse()
                    .unwrap(),
            )
            .await
            .unwrap();
    }
}
