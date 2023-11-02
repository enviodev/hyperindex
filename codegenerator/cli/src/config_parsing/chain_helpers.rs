use anyhow::anyhow;
use anyhow::Context;
use clap::ValueEnum;
use ethers::etherscan;
use serde::{Deserialize, Serialize};
use strum::FromRepr;
use strum_macros::{Display, EnumIter, EnumString};
use subenum::subenum;

#[subenum(
    NetworkWithExplorer,
    SupportedNetwork,
    SkarNetwork,
    EthArchiveNetwork,
    GraphNetwork
)]
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
        SupportedNetwork,
        NetworkWithExplorer,
        SkarNetwork,
        GraphNetwork(serde(rename = "mainnet"))
    )]
    EthereumMainnet = 1,
    #[subenum(SupportedNetwork, NetworkWithExplorer, SkarNetwork, GraphNetwork)]
    Goerli = 5,
    #[subenum(
        SupportedNetwork,
        NetworkWithExplorer,
        EthArchiveNetwork,
        SkarNetwork,
        GraphNetwork
    )]
    Optimism = 10,
    #[subenum(SupportedNetwork, SkarNetwork, GraphNetwork)]
    Base = 8453,
    #[subenum(
        SupportedNetwork,
        NetworkWithExplorer,
        EthArchiveNetwork,
        SkarNetwork,
        GraphNetwork
    )]
    Bsc = 56,
    #[subenum(GraphNetwork)]
    PoaSokol = 77,
    #[subenum(GraphNetwork)]
    Chapel = 97,
    #[subenum(GraphNetwork)]
    PoaCore = 99,
    #[subenum(SupportedNetwork, SkarNetwork, GraphNetwork)]
    Gnosis = 100,
    #[subenum(GraphNetwork)]
    Fuse = 122,
    #[subenum(GraphNetwork)]
    Fantom = 250,
    #[subenum(
        SupportedNetwork,
        NetworkWithExplorer,
        SkarNetwork,
        EthArchiveNetwork,
        GraphNetwork(serde(rename = "matic"))
    )]
    Polygon = 137,
    Boba = 288,
    #[subenum(NetworkWithExplorer, GraphNetwork)]
    OptimismGoerli = 420,
    #[subenum(GraphNetwork)]
    Clover = 1023,
    #[subenum(GraphNetwork)]
    Moonbeam = 1284,
    #[subenum(GraphNetwork)]
    Moonriver = 1285,
    #[subenum(GraphNetwork)]
    Mbase = 1287,
    #[subenum(GraphNetwork)]
    FantomTestnet = 4002,
    #[subenum(
        SupportedNetwork,
        NetworkWithExplorer,
        EthArchiveNetwork,
        GraphNetwork,
        SkarNetwork
    )]
    ArbitrumOne = 42161,
    #[subenum(NetworkWithExplorer, GraphNetwork)]
    ArbitrumGoerli = 421613,
    #[subenum(GraphNetwork)]
    Celo = 42220,
    #[subenum(GraphNetwork)]
    Fuji = 43113,
    #[subenum(SupportedNetwork, NetworkWithExplorer, EthArchiveNetwork, GraphNetwork)]
    Avalanche = 43114,
    #[subenum(GraphNetwork)]
    CeloAlfajores = 44787,
    #[subenum(NetworkWithExplorer, GraphNetwork)]
    Mumbai = 80001,
    #[subenum(GraphNetwork)]
    Aurora = 1313161554,
    #[subenum(GraphNetwork)]
    AuroraTestnet = 1313161555,
    Harmony = 1666600000,
    #[subenum(SupportedNetwork, EthArchiveNetwork, GraphNetwork)]
    BaseTestnet = 84531,
    #[subenum(GraphNetwork)]
    ZksyncEra = 324,
    #[subenum(NetworkWithExplorer, SkarNetwork, GraphNetwork)]
    Sepolia = 11155111,
    #[subenum(SupportedNetwork, EthArchiveNetwork, SkarNetwork)]
    Linea = 59144,
    #[subenum(GraphNetwork)]
    Rinkeby = 4,
    #[subenum(GraphNetwork)]
    ZksyncEraTestnet = 280,
    #[subenum(GraphNetwork)]
    PolygonZkevmTestnet = 1422,
    #[subenum(GraphNetwork)]
    PolygonZkevm = 1101,
    #[subenum(GraphNetwork)]
    ScrollSepolia = 534351,
    #[subenum(GraphNetwork)]
    Scroll = 534352,
}

impl Network {
    pub fn get_network_id(&self) -> u64 {
        self.clone() as u64
    }

    pub fn from_network_id(id: u64) -> anyhow::Result<Self> {
        Network::from_repr(id)
            .ok_or_else(|| anyhow!("Failed converting network_id {} to network name", id))
    }
}

pub struct BlockExplorerApi {
    pub base_url: String,
    pub api_key: String,
}

impl NetworkWithExplorer {
    // Function to return the chain ID of the network based on the network name
    pub fn get_block_explorer_api(&self) -> BlockExplorerApi {
        let (base_url_str, api_key_str) = match self {
            NetworkWithExplorer::EthereumMainnet => {
                ("api.etherscan.io", "WR5JNQKI5HJ8EP9EGCBY544AH8Y6G8KFZV")
            }
            NetworkWithExplorer::Goerli => (
                "api-goerli.etherscan.io",
                "WR5JNQKI5HJ8EP9EGCBY544AH8Y6G8KFZV",
            ),
            NetworkWithExplorer::Optimism => (
                "api-optimistic.etherscan.io",
                "Z1A9EP3DSM9SNZ2IDMAVPPGYDDG6FRYINA",
            ),
            //TODO: GET BSC API KEY
            NetworkWithExplorer::Bsc => ("api.bscscan.com", "BSC_API_KEY_PLACE_HOLDER"),
            NetworkWithExplorer::Polygon => {
                ("api.polygonscan.com", "I9CKKRUZBHCI1TWN8R44EIUBY6U2GI48FP")
            }

            NetworkWithExplorer::OptimismGoerli => (
                "api-goerli-optimistic.etherscan.io",
                "Z1A9EP3DSM9SNZ2IDMAVPPGYDDG6FRYINA",
            ),
            NetworkWithExplorer::ArbitrumOne => {
                ("api.arbiscan.io", "1W3AF7G7TRTGSPASM11SHZSIZRII5EX92D")
            }

            NetworkWithExplorer::ArbitrumGoerli => (
                "api-goerli.arbiscan.io",
                "1W3AF7G7TRTGSPASM11SHZSIZRII5EX92D",
            ),
            NetworkWithExplorer::Avalanche => {
                ("api.snowtrace.io", "EJZP7RY157YUI981Q6DMHFZ24U2ET8EHCK")
            }
            NetworkWithExplorer::Mumbai => (
                "api-testnet.polygonscan.com",
                "I9CKKRUZBHCI1TWN8R44EIUBY6U2GI48FP",
            ),
            NetworkWithExplorer::Sepolia => (
                "api-sepolia.etherscan.io",
                "WR5JNQKI5HJ8EP9EGCBY544AH8Y6G8KFZV",
            ),
        };

        BlockExplorerApi {
            base_url: base_url_str.to_string(),
            api_key: api_key_str.to_string(),
        }
    }
}

pub fn get_etherscan_client(network: &NetworkWithExplorer) -> anyhow::Result<etherscan::Client> {
    let BlockExplorerApi { api_key, .. } = network.get_block_explorer_api();
    let chain_id = Network::from(*network).get_network_id();

    let ethers_chain = ethers::types::Chain::try_from(chain_id)
        .context("converting network id to ethers chain")?;

    let client =
        etherscan::Client::new(ethers_chain, api_key).context("creating client for network")?;

    Ok(client)
}

#[cfg(test)]
mod test {

    use crate::config_parsing::chain_helpers::Network;

    use super::{GraphNetwork, NetworkWithExplorer, SupportedNetwork};

    use strum::IntoEnumIterator;

    #[test]
    fn all_network_names_have_ethers_chain() {
        for network in NetworkWithExplorer::iter() {
            ethers::types::Chain::try_from(network as u64).unwrap();
        }
    }

    #[test]
    fn network_deserialize() {
        let names = r#"["ethereum-mainnet", "polygon"]"#;
        let names_des: Vec<SupportedNetwork> = serde_json::from_str(names).unwrap();
        let expected = vec![SupportedNetwork::EthereumMainnet, SupportedNetwork::Polygon];
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
         * https://github.com/graphprotocol/graph-tooling/blob/main/packages/cli/src/protocols/index.ts#L76-L117
         */
        let networks = r#"[
        "mainnet",
        "rinkeby",
        "goerli",
        "poa-core",
        "poa-sokol",
        "gnosis",
        "matic",
        "mumbai",
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

        let supported_graph_networks = serde_json::from_str::<Vec<GraphNetwork>>(networks).unwrap();

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
}
