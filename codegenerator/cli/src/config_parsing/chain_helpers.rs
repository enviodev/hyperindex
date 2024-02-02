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
    Chapel = 97,
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
    #[subenum(GraphNetwork)]
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
    #[subenum(HypersyncNetwork)]
    // Explorers:
    // https://explorer.zora.energy/
    Zora = 7777777,
    #[subenum(HypersyncNetwork)]
    // Explorers:
    // https://explorer.publicgoods.network/
    PublicGoods = 424,
    #[subenum(HypersyncNetwork)]
    // Explorers:
    // Blockscout: https://explorer-mainnet-algorand-rollup.a1.milkomeda.com/
    A1Milkomeda = 2002,
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
    pub fn get_block_explorer_api(&self, rate_limit_retry_count: usize) -> BlockExplorerApi {
        let api_keys = match self {
            NetworkWithExplorer::EthereumMainnet => [
                "9NNX6U3WXH8VWKSUCZYSYMH38A3Z9V925B",
                "FBVF62I851WY2A3Z5GUP2M6KQWR3M196SJ",
                "5GXXUX8RHG798TXASS8G9U6BRAAGM4SP7H",
            ],
            NetworkWithExplorer::Goerli => [
                "9NNX6U3WXH8VWKSUCZYSYMH38A3Z9V925B",
                "FBVF62I851WY2A3Z5GUP2M6KQWR3M196SJ",
                "5GXXUX8RHG798TXASS8G9U6BRAAGM4SP7H",
            ],
            NetworkWithExplorer::Holesky => [
                "9NNX6U3WXH8VWKSUCZYSYMH38A3Z9V925B",
                "FBVF62I851WY2A3Z5GUP2M6KQWR3M196SJ",
                "5GXXUX8RHG798TXASS8G9U6BRAAGM4SP7H",
            ],
            NetworkWithExplorer::Optimism => [
                "ZWBZ1HIDFC5GCUUWSPHUFMYY9FZI7BTD5Y",
                "MCZM3IWFFBTJYZNYFEDGXS4NKQMW19G8H8",
                "YSYDI8FPNKGDDQU5349NWCVCQKI164IRBD",
            ],
            NetworkWithExplorer::Bsc => [
                "9YEBZHXJW7Q9RCRHHXRFJEQ4X2YIQ7D6PI",
                "G5NFVBPX2QHPUAPBU91RBW9AEYJDWNTIJ7",
                "VKW31ERMD1K97NWDC45Y8MWC2YSA3DVY4M",
            ],
            NetworkWithExplorer::Polygon => [
                "7KQZVW13K3VU2SAIUVNHG4M3HPTMHD9T7Z",
                "YCIATTDSTMJXNNMTUWFJS3ZMG83DJ7U3N2",
                "UXZJ3U5QBZIK161QJDCM8WDVTKRZ7KTG9K",
            ],
            NetworkWithExplorer::OptimismGoerli => [
                "ZWBZ1HIDFC5GCUUWSPHUFMYY9FZI7BTD5Y",
                "MCZM3IWFFBTJYZNYFEDGXS4NKQMW19G8H8",
                "YSYDI8FPNKGDDQU5349NWCVCQKI164IRBD",
            ],
            NetworkWithExplorer::OptimismSepolia => [
                "ZWBZ1HIDFC5GCUUWSPHUFMYY9FZI7BTD5Y",
                "MCZM3IWFFBTJYZNYFEDGXS4NKQMW19G8H8",
                "YSYDI8FPNKGDDQU5349NWCVCQKI164IRBD",
            ],
            NetworkWithExplorer::ArbitrumOne => [
                "3T4HN3KASB3IPQEZX21A9EXFFDKBNIRQ3R",
                "F3VXQYQSV2IKB8UCMNASMPWP39GAN8JDFY",
                "G65DZIAMA9756ZS875UDBFY6UH4W5VJ5DW",
            ],
            NetworkWithExplorer::ArbitrumGoerli => [
                "3T4HN3KASB3IPQEZX21A9EXFFDKBNIRQ3R",
                "F3VXQYQSV2IKB8UCMNASMPWP39GAN8JDFY",
                "G65DZIAMA9756ZS875UDBFY6UH4W5VJ5DW",
            ],
            NetworkWithExplorer::ArbitrumNova => [
                "3T4HN3KASB3IPQEZX21A9EXFFDKBNIRQ3R",
                "F3VXQYQSV2IKB8UCMNASMPWP39GAN8JDFY",
                "G65DZIAMA9756ZS875UDBFY6UH4W5VJ5DW",
            ],
            // TODO
            NetworkWithExplorer::Avalanche => [
                "EJZP7RY157YUI981Q6DMHFZ24U2ET8EHCK",
                "EJZP7RY157YUI981Q6DMHFZ24U2ET8EHCK",
                "EJZP7RY157YUI981Q6DMHFZ24U2ET8EHCK",
            ],
            NetworkWithExplorer::Mumbai => [
                "7KQZVW13K3VU2SAIUVNHG4M3HPTMHD9T7Z",
                "YCIATTDSTMJXNNMTUWFJS3ZMG83DJ7U3N2",
                "UXZJ3U5QBZIK161QJDCM8WDVTKRZ7KTG9K",
            ],
            NetworkWithExplorer::Sepolia => [
                "9NNX6U3WXH8VWKSUCZYSYMH38A3Z9V925B",
                "FBVF62I851WY2A3Z5GUP2M6KQWR3M196SJ",
                "5GXXUX8RHG798TXASS8G9U6BRAAGM4SP7H",
            ],
            NetworkWithExplorer::Gnosis => [
                "BYHU1N8Y1R3J9H5VA9DN3K7NDIIESYW9JY",
                "9CI9358SI6SY8YRM6QDMCRRUGG4T72VT1A",
                "8TC268FB21VFAKN6S5VXKHKQTM2FJGAYYX",
            ],
            NetworkWithExplorer::Linea => [
                "PVMK8H27KU5GH43T3TXM8AV66TP3ZDUNIF",
                "6JG3C8ACZGAAXDH575MQ4D1FEFTZ881GY3",
                "XIB1FPBWBFWVWBJU6Q1TCSJ2NXEB5SGUBW",
            ],
            NetworkWithExplorer::Base => [
                "X5NZKY2RDIX8KVDDATSUY56HAKYS2QR44N",
                "SP77NC1P7IX1ZJJW327IZYXKAX8QB9XJMN",
                "Z564GWWJGQ7PFC8FAPMMASZ6QZZAPNTT5X",
            ],
            NetworkWithExplorer::BaseSepolia => [
                "X5NZKY2RDIX8KVDDATSUY56HAKYS2QR44N",
                "SP77NC1P7IX1ZJJW327IZYXKAX8QB9XJMN",
                "Z564GWWJGQ7PFC8FAPMMASZ6QZZAPNTT5X",
            ],
            NetworkWithExplorer::Scroll => [
                "5747W9V9U5TB71SEQVJ1MV488ZKUPRDY5P",
                "NGTI7FCEWXB9S8QYU96PV94VYWN3K3SU6I",
                "DAM7Q5P727XZ8D4QX5TFTDDVJBSATS6G38",
            ],
            NetworkWithExplorer::PolygonZkevm => [
                "CC63UV4JWQY4ZJ4Q3FUBGNWKV7NUX6HDW7",
                "EW6D5AUVNJXAQRHBX3ZDKQGK6M99MP8J9T",
                "68JQBIHK1ANMHVBK8EEGKQDK7H2K9YCD2V",
            ],
            NetworkWithExplorer::Celo => [
                "RBX9BZBUYIDTZHR6ESSK1JMVC34FDU7KK8",
                "Y9AHMQWF1Z4H1CPT3MCP36Q2X9VVF4CT8S",
                "JGWV53QKINTW3SRJSJ9V6SJ9KDUYZXMAA8",
            ],
            NetworkWithExplorer::Kroma => [
                "9V3VRR1N8293VBBVXNQ4HS6Z6HSJ4KWQPK",
                "JG6CDQYK7CQWAXDBF1M4N84PW12PCXNRVV",
                "RURK915VJUAB7W6T5U3JYHQ3R9ZFIN7JEB",
            ],
            NetworkWithExplorer::Moonbeam => [
                "E6CBETQ1UWJXI54Q5SVBDB9F91ZB45PVRG",
                "CNWU4T5RCN31JUK99HR4P4XV2EUEVQ7P62",
                "TGUAN47MYKD8F5RWW66NT8RZSQYRUNGEWH",
            ],
            NetworkWithExplorer::Fantom => [
                "VFWQXQVIZ9GN7IAWNAS8RZKNV9DEUX179Z",
                "INIU3I5SNKAVJ8NZB1VVMXW8TNCGQ38AE7",
                "ZMBT883ZBZDZQ5SWKZADDKTB1E7P3JCZHD",
            ],
        };

        // Retrieving the index of the api_key to be used based on the rate_limit_retry_count
        let api_key_index = rate_limit_retry_count % api_keys.len();

        // Selecting the api_key to be used based on the index
        let api_key = api_keys[api_key_index];

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
            NetworkWithExplorer::BaseSepolia => BlockExplorerApi::custom(
                "sepolia.basescan.org",
                "api.sepolia.basescan.org",
                api_key,
            ),
            NetworkWithExplorer::OptimismSepolia => BlockExplorerApi::custom(
                "sepolia-optimistic.etherscan.io",
                "api.sepolia-optimistic.etherscan.io",
                api_key,
            ),
            _ => BlockExplorerApi::default_ethers(api_key),
        }
    }
}

pub fn get_etherscan_client(
    network: &NetworkWithExplorer,
    rate_limit_retry_count: usize,
) -> anyhow::Result<etherscan::Client> {
    let client = match network.get_block_explorer_api(rate_limit_retry_count) {
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
            // Test with 3 rate limit retries as we have 3 api keys per network
            for rate_limit_retry_count in 0..4 {
                get_etherscan_client(&network, rate_limit_retry_count).unwrap();
            }
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
        "base-goerli",
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
        let rate_limit_retry_count = 0;
        let client = get_etherscan_client(&network, rate_limit_retry_count).unwrap();

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
