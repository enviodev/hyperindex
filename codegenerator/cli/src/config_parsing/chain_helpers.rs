use anyhow::anyhow;
use anyhow::Context;
use clap::ValueEnum;
use ethers::etherscan;
use serde::{Deserialize, Serialize};
use strum::FromRepr;
use strum_macros::{Display, EnumIter, EnumString};
use subenum::subenum;

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
    #[subenum(HypersyncNetwork, NetworkWithExplorer, GraphNetwork)]
    Bsc = 56,
    #[subenum(GraphNetwork)]
    PoaSokol = 77,
    #[subenum(GraphNetwork)]
    Chapel = 97,
    #[subenum(GraphNetwork)]
    PoaCore = 99,
    #[subenum(HypersyncNetwork, NetworkWithExplorer, GraphNetwork)]
    Gnosis = 100,
    #[subenum(GraphNetwork)]
    Fuse = 122,
    #[subenum(GraphNetwork)]
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
    #[subenum(NetworkWithExplorer, GraphNetwork)]
    ArbitrumGoerli = 421613,
    #[subenum(HypersyncNetwork, GraphNetwork, NetworkWithExplorer)]
    // Blockscout: https://explorer.celo.org/mainnet/
    Celo = 42220,
    #[subenum(GraphNetwork)]
    Fuji = 43113,
    #[subenum(HypersyncNetwork, NetworkWithExplorer, GraphNetwork)]
    Avalanche = 43114,
    #[subenum(GraphNetwork)]
    CeloAlfajores = 44787,
    #[subenum(HypersyncNetwork, NetworkWithExplorer, GraphNetwork)]
    Mumbai = 80001,
    #[subenum(GraphNetwork)]
    Aurora = 1313161554,
    #[subenum(GraphNetwork)]
    AuroraTestnet = 1313161555,
    Harmony = 1666600000,
    #[subenum(GraphNetwork)]
    BaseTestnet = 84531,
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
    #[subenum(HypersyncNetwork)]
    // Explorers:
    // blockscout: https://explorer.jolnir.taiko.xyz/
    TaikoJolnr = 167007,
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
    OkbcTestnet = 195,

    #[subenum(HypersyncNetwork, NetworkWithExplorer)]
    Holesky = 17000,
    #[subenum(HypersyncNetwork)]
    // Explorers:
    // https://gnosis-chiado.blockscout.com/
    GnosisChiado = 10200,
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

pub enum BlockExplorerApi {
    DefaultEthers {
        api_key: String,
    },
    Custom {
        //eg. "https://gnosisscan.io/"
        base_url: String,
        //eg. "https://api.gnosisscan.io/api/"
        api_url: String,
        api_key: String,
    },
}

impl BlockExplorerApi {
    pub fn default_ethers(api_key: &str) -> Self {
        Self::DefaultEthers {
            api_key: api_key.to_string(),
        }
    }

    fn custom(base_url: &str, api_url: &str, api_key: &str) -> Self {
        let base_url = format!("https://{}/", base_url);
        let api_url = format!("https://{}/api/", api_url);
        Self::Custom {
            base_url,
            api_url,
            api_key: api_key.to_string(),
        }
    }
}

impl NetworkWithExplorer {
    // Function to return the chain ID of the network based on the network name
    pub fn get_block_explorer_api(&self) -> BlockExplorerApi {
        let api_key = match self {
            NetworkWithExplorer::EthereumMainnet => "WR5JNQKI5HJ8EP9EGCBY544AH8Y6G8KFZV",
            NetworkWithExplorer::Goerli => "WR5JNQKI5HJ8EP9EGCBY544AH8Y6G8KFZV",
            NetworkWithExplorer::Holesky => "WR5JNQKI5HJ8EP9EGCBY544AH8Y6G8KFZV",
            NetworkWithExplorer::Optimism => "Z1A9EP3DSM9SNZ2IDMAVPPGYDDG6FRYINA",
            NetworkWithExplorer::Bsc => "ZZMAWTWCP7T2MP855DA87A3ND6R13GT3K8",
            NetworkWithExplorer::Polygon => "I9CKKRUZBHCI1TWN8R44EIUBY6U2GI48FP",
            NetworkWithExplorer::OptimismGoerli => "Z1A9EP3DSM9SNZ2IDMAVPPGYDDG6FRYINA",
            NetworkWithExplorer::ArbitrumOne => "1W3AF7G7TRTGSPASM11SHZSIZRII5EX92D",
            NetworkWithExplorer::ArbitrumGoerli => "1W3AF7G7TRTGSPASM11SHZSIZRII5EX92D",
            NetworkWithExplorer::Avalanche => "EJZP7RY157YUI981Q6DMHFZ24U2ET8EHCK",
            NetworkWithExplorer::Mumbai => "I9CKKRUZBHCI1TWN8R44EIUBY6U2GI48FP",
            NetworkWithExplorer::Sepolia => "WR5JNQKI5HJ8EP9EGCBY544AH8Y6G8KFZV",
            NetworkWithExplorer::Gnosis => "5RHWVXQ7TQ1B4G1NPX4J7MF3B3ICDU3KEV",
            NetworkWithExplorer::Linea => "TYCR43IQ5U85DKZXQG8MQIJI7922DVHZX5",
            NetworkWithExplorer::Base => "EHB4U5A97C3EGDMSKDY8T5TQ9DXU9Q7HT3",
            NetworkWithExplorer::Scroll => "ZC5BE2NT8UU358184YSBMIFU3F9ZPG5CKX",
            NetworkWithExplorer::PolygonZkevm => "2GSEPCMXK4J9CMBMG2AFXJJZYMWA3J4A2Z",
            NetworkWithExplorer::Celo => "PT6X2G4Q8YKFC2KU4FCDUUDCXPA57NC7NB",
            NetworkWithExplorer::Kroma => "PNT5V8B3TR5V7AA2IRHD8YB81F5W83YG98",
            NetworkWithExplorer::Moonbeam => "47H94RVTAKCDKNSMBEX15F5AXDAB4DWRY5",
        };

        //Define all custom block explorer definitions at the top otherwise default with ethers api
        match self {
            NetworkWithExplorer::Gnosis => {
                BlockExplorerApi::custom("gnosisscan.io", "api.gnosisscan.io", api_key)
            }
            NetworkWithExplorer::Holesky => BlockExplorerApi::custom(
                "holesky.etherscan.io",
                "api.holesky.etherscan.io",
                api_key,
            ),
            NetworkWithExplorer::Scroll => {
                BlockExplorerApi::custom("scrollscan.com", "api.scrollscan.com", api_key)
            }
            NetworkWithExplorer::Kroma => {
                BlockExplorerApi::custom("kromascan.com", "api.kromascan.com", api_key)
            }
            _ => BlockExplorerApi::default_ethers(api_key),
        }
    }
}

pub fn get_etherscan_client(network: &NetworkWithExplorer) -> anyhow::Result<etherscan::Client> {
    let client = match network.get_block_explorer_api() {
        BlockExplorerApi::DefaultEthers { api_key } => {
            let chain_id = Network::from(*network).get_network_id();

            let ethers_chain = ethers::types::Chain::try_from(chain_id)
                .context("Failed converting network with explorer id to ethers chain")?;

            etherscan::Client::new(ethers_chain, api_key)
                .context("Failed creating client for network")?
        }

        BlockExplorerApi::Custom {
            base_url,
            api_url,
            api_key,
        } => etherscan::Client::builder()
            .with_url(&base_url)
            .context(format!(
                "Failed building custom client at base url {}",
                base_url
            ))?
            .with_api_url(&api_url)
            .context(format!(
                "Failed building custom client at api url {}",
                api_url
            ))?
            .with_api_key(api_key)
            .build()
            .context("Failed build custom client")?,
    };

    Ok(client)
}

#[cfg(test)]
mod test {

    use crate::config_parsing::chain_helpers::Network;

    use super::{get_etherscan_client, GraphNetwork, HypersyncNetwork, NetworkWithExplorer};

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
