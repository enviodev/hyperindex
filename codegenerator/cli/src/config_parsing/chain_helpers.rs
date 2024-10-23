use anyhow::anyhow;

use clap::ValueEnum;
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
    #[subenum(HypersyncNetwork, NetworkWithExplorer)]
    Amoy = 80002,

    #[subenum(GraphNetwork)]
    ArbitrumGoerli = 421613,

    #[subenum(HypersyncNetwork, NetworkWithExplorer)]
    ArbitrumNova = 42170,

    #[subenum(HypersyncNetwork, NetworkWithExplorer, GraphNetwork)]
    ArbitrumOne = 42161,

    #[subenum(HypersyncNetwork, NetworkWithExplorer, GraphNetwork)]
    ArbitrumSepolia = 421614,

    #[subenum(NetworkWithExplorer)]
    ArbitrumTestnet = 421611,

    #[subenum(HypersyncNetwork, GraphNetwork)]
    // Blockscout: https://explorer.aurora.dev/
    Aurora = 1313161554,

    #[subenum(GraphNetwork)]
    AuroraTestnet = 1313161555,

    #[subenum(HypersyncNetwork, GraphNetwork, NetworkWithExplorer)]
    Avalanche = 43114,

    #[subenum(HypersyncNetwork, NetworkWithExplorer, GraphNetwork)]
    Base = 8453,

    #[subenum(GraphNetwork(serde(rename = "base-testnet")))]
    BaseGoerli = 84531,

    #[subenum(HypersyncNetwork, NetworkWithExplorer)]
    // explorers:
    // https://sepolia.basescan.org/
    // https://base-sepolia.blockscout.com/
    BaseSepolia = 84532,

    #[subenum(HypersyncNetwork)]
    BerachainBartio = 80084,

    #[subenum(HypersyncNetwork, NetworkWithExplorer)]
    Blast = 81457,

    #[subenum(HypersyncNetwork, NetworkWithExplorer)]
    BlastSepolia = 168587773,

    #[subenum(HypersyncNetwork, NetworkWithExplorer)]
    Boba = 288,

    #[subenum(HypersyncNetwork, NetworkWithExplorer, GraphNetwork)]
    Bsc = 56,

    #[subenum(
        HypersyncNetwork,
        NetworkWithExplorer,
        GraphNetwork(serde(rename = "chapel"))
    )]
    BscTestnet = 97,

    #[subenum(HypersyncNetwork)]
    // Explorers:
    // Blockscout: https://explorer-mainnet-cardano-evm.c1.milkomeda.com/
    C1Milkomeda = 2001,

    #[subenum(HypersyncNetwork, GraphNetwork, NetworkWithExplorer)]
    Celo = 42220,

    #[subenum(GraphNetwork, NetworkWithExplorer)]
    CeloAlfajores = 44787,

    #[subenum(HypersyncNetwork)]
    Chiliz = 8888,

    #[subenum(HypersyncNetwork)]
    // blocksout: https://explorer.devnet.citrea.xyz/
    CitreaDevnet = 62298,

    #[subenum(GraphNetwork)]
    Clover = 1023,

    #[subenum(HypersyncNetwork)]
    // Explorers:
    // https://crab.subscan.io/
    Crab = 44,

    #[subenum(HypersyncNetwork)]
    // Explorers:
    // NOTE: this does have contract verification and an api to get verified contracts, but this
    // breaks with the current setup. TODO: get non-etherscan contract verification working.
    // https://cyber.socialscan.io/
    Cyber = 7560,

    #[subenum(HypersyncNetwork)]
    // Explorers:
    // https://darwinia.subscan.io/
    Darwinia = 46,

    // Still syncing
    // #[subenum(HypersyncNetwork)]
    // // Explorers:
    // // https://explorer.degen.tips/
    // Degen = 666666666,
    #[subenum(
        HypersyncNetwork,
        NetworkWithExplorer,
        GraphNetwork(serde(rename = "mainnet"))
    )]
    EthereumMainnet = 1,

    #[subenum(HypersyncNetwork, NetworkWithExplorer, GraphNetwork)]
    Fantom = 250,

    #[subenum(GraphNetwork, NetworkWithExplorer)]
    FantomTestnet = 4002,

    #[subenum(HypersyncNetwork)]
    // Explorers:
    // https://explorer.testnet.fhenix.zone/ (blockscout)
    FhenixTestnet = 42069,

    #[subenum(HypersyncNetwork)]
    // Explorers:
    // Blockscout: https://flare-explorer.flare.network/
    // Routescan: https://flarescan.com/
    Flare = 14,

    #[subenum(HypersyncNetwork, GraphNetwork, NetworkWithExplorer)]
    Fuji = 43113,

    #[subenum(GraphNetwork)]
    Fuse = 122,

    #[subenum(HypersyncNetwork)]
    GaladrielDevnet = 696969,

    #[subenum(HypersyncNetwork, NetworkWithExplorer, GraphNetwork)]
    Gnosis = 100,

    #[subenum(HypersyncNetwork)]
    // Explorers:
    // https://gnosis-chiado.blockscout.com/
    GnosisChiado = 10200,

    #[subenum(HypersyncNetwork, NetworkWithExplorer, GraphNetwork)]
    Goerli = 5,

    #[subenum(HypersyncNetwork)]
    // Explorers:
    // https://explorer.harmony.one/
    // https://getblock.io/explorers/harmony/
    Harmony = 1666600000, // shard 0

    #[subenum(HypersyncNetwork, NetworkWithExplorer)]
    Holesky = 17000,

    #[subenum(HypersyncNetwork)]
    IncoGentryTestnet = 9090,

    #[subenum(HypersyncNetwork)]
    Kroma = 255,

    // Still syncing
    // #[subenum(HypersyncNetwork)]
    // KakarotSepolia = 1802203764,
    #[subenum(HypersyncNetwork, NetworkWithExplorer)]
    Linea = 59144,

    #[subenum(NetworkWithExplorer)]
    LineaSepolia = 59141,

    #[subenum(HypersyncNetwork)]
    // Explorers:
    // https://explorer.execution.mainnet.lukso.network/
    // https://blockscout.com/lukso/l14
    Lukso = 42,

    #[subenum(HypersyncNetwork)]
    // Explorers:
    // blockscout: https://pacific-explorer.manta.network/
    // w3w.ai: https://manta.socialscan.io/
    Manta = 169,

    #[subenum(HypersyncNetwork)]
    // Explorers:
    // https://explorer.mantle.xyz/
    // Routescan: https://mantlescan.info/
    Mantle = 5000,

    #[subenum(GraphNetwork, NetworkWithExplorer)]
    Mbase = 1287,

    #[subenum(HypersyncNetwork, NetworkWithExplorer)]
    Metis = 1088,

    #[subenum(HypersyncNetwork)]
    MevCommit = 17864,

    #[subenum(HypersyncNetwork, NetworkWithExplorer, GraphNetwork)]
    Moonbeam = 1284,

    #[subenum(GraphNetwork, NetworkWithExplorer)]
    Moonriver = 1285,

    // Still syncing
    // #[subenum(HypersyncNetwork)]
    // MorphTestnet = 2810,
    #[subenum(GraphNetwork)]
    Mumbai = 80001,

    #[subenum(HypersyncNetwork)]
    // Explorers:
    // https://neonscan.org/
    // https://neon.blockscout.com/
    NeonEvm = 245022934,

    #[subenum(HypersyncNetwork, NetworkWithExplorer, GraphNetwork)]
    Optimism = 10,

    #[subenum(GraphNetwork)]
    OptimismGoerli = 420,

    #[subenum(HypersyncNetwork, NetworkWithExplorer)]
    // Alt-explorer:
    // https://optimism-sepolia.blockscout.com/
    OptimismSepolia = 11155420,

    #[subenum(GraphNetwork)]
    PoaCore = 99,

    #[subenum(GraphNetwork)]
    PoaSokol = 77,

    #[subenum(
        HypersyncNetwork,
        NetworkWithExplorer,
        GraphNetwork(serde(rename = "matic"))
    )]
    Polygon = 137,

    #[subenum(GraphNetwork, HypersyncNetwork, NetworkWithExplorer)]
    PolygonZkevm = 1101,

    #[subenum(GraphNetwork, NetworkWithExplorer)]
    PolygonZkevmTestnet = 1442,

    #[subenum(GraphNetwork)]
    Rinkeby = 4,

    #[subenum(HypersyncNetwork)]
    // Explorers:
    // https://explorer.rsk.co/
    // https://rootstock.blockscout.com/
    Rsk = 30,

    // Still syncing
    // #[subenum(HypersyncNetwork)]
    // Saakuru = 7225878,
    #[subenum(GraphNetwork, HypersyncNetwork, NetworkWithExplorer)]
    Scroll = 534352,

    #[subenum(GraphNetwork, NetworkWithExplorer)]
    ScrollSepolia = 534351,

    #[subenum(HypersyncNetwork, NetworkWithExplorer, GraphNetwork)]
    Sepolia = 11155111,

    #[subenum(HypersyncNetwork)]
    // Explorers:
    // https://explorer.evm.shimmer.network/
    ShimmerEvm = 148,

    #[subenum(HypersyncNetwork)]
    SophonTestnet = 531050104,

    #[subenum(HypersyncNetwork)]
    // Explorers:
    // https://www.oklink.com/xlayer
    XLayer = 196,

    #[subenum(HypersyncNetwork)]
    // Explorers:
    // https://www.oklink.com/x1-test
    XLayerTestnet = 195,

    #[subenum(HypersyncNetwork)]
    // Explorers:
    // https://explorer.zetachain.com/
    // https://zetachain.explorers.guru/
    Zeta = 7000,

    #[subenum(HypersyncNetwork)]
    Zircuit = 48900,

    #[subenum(HypersyncNetwork, GraphNetwork)]
    ZksyncEra = 324,

    #[subenum(GraphNetwork)]
    ZksyncEraTestnet = 280,

    #[subenum(HypersyncNetwork)]
    // Explorers:
    // https://explorer.zora.energy/
    Zora = 7777777,
}

impl Network {
    pub fn get_network_id(&self) -> u64 {
        self.clone() as u64
    }

    pub fn from_network_id(id: u64) -> anyhow::Result<Self> {
        Network::from_repr(id)
            .ok_or_else(|| anyhow!("Failed converting network_id {} to network name", id))
    }

    /// Returns the end block for this network if it is finite
    pub fn get_finite_end_block(&self) -> Option<u64> {
        match self {
            Self::Goerli => Some(10_387_962),
            Self::Mumbai => Some(47_002_303),
            _ => None,
        }
    }

    //TODO: research a sufficient threshold for all chain (some should be 0)
    pub fn get_confirmed_block_threshold(&self) -> i32 {
        match self {
            //Reorgs do not happen on these networks
            Network::ArbitrumTestnet
            | Network::ArbitrumGoerli
            | Network::ArbitrumNova
            | Network::ArbitrumOne
            | Network::ArbitrumSepolia
            | Network::CitreaDevnet
            | Network::Optimism
            | Network::OptimismGoerli
            | Network::OptimismSepolia => 0,
            //TODO: research a sufficient threshold for all chains
            Network::Amoy
            | Network::Avalanche
            | Network::Aurora
            | Network::AuroraTestnet
            | Network::Base
            | Network::BaseGoerli
            | Network::BaseSepolia
            | Network::BerachainBartio
            | Network::Blast
            | Network::BlastSepolia
            | Network::Boba
            | Network::Bsc
            | Network::BscTestnet
            | Network::C1Milkomeda
            | Network::Celo
            | Network::CeloAlfajores
            | Network::Chiliz
            | Network::Clover
            | Network::Crab
            | Network::Cyber
            | Network::Darwinia
            | Network::EthereumMainnet
            | Network::Fantom
            | Network::FantomTestnet
            | Network::FhenixTestnet
            | Network::Flare
            | Network::Fuji
            | Network::Fuse
            | Network::GaladrielDevnet
            | Network::Gnosis
            | Network::GnosisChiado
            | Network::Goerli
            | Network::Harmony
            | Network::Holesky
            | Network::IncoGentryTestnet
            | Network::Kroma
            | Network::Linea
            | Network::LineaSepolia
            | Network::Lukso
            | Network::Manta
            | Network::Mantle
            | Network::MevCommit
            | Network::Metis
            | Network::Moonbeam
            | Network::Moonriver
            | Network::Mumbai
            | Network::Mbase
            | Network::NeonEvm
            | Network::PoaCore
            | Network::PoaSokol
            | Network::Polygon
            | Network::PolygonZkevm
            | Network::PolygonZkevmTestnet
            | Network::Rinkeby
            | Network::Rsk
            | Network::Scroll
            | Network::ScrollSepolia
            | Network::Sepolia
            | Network::ShimmerEvm
            | Network::SophonTestnet
            | Network::XLayer
            | Network::XLayerTestnet
            | Network::Zeta
            | Network::Zircuit
            | Network::ZksyncEra
            | Network::ZksyncEraTestnet
            | Network::Zora => DEFAULT_CONFIRMED_BLOCK_THRESHOLD,
        }
    }
}

impl HypersyncNetwork {
    // This is a custom iterator that returns all the HypersyncNetwork enums that is made public accross crates (for convenience)
    pub fn iter_hypersync_networks() -> impl Iterator<Item = HypersyncNetwork> {
        HypersyncNetwork::iter()
    }
}

pub fn get_confirmed_block_threshold_from_id(id: u64) -> i32 {
    Network::from_network_id(id).map_or(DEFAULT_CONFIRMED_BLOCK_THRESHOLD, |n| {
        n.get_confirmed_block_threshold()
    })
}

#[cfg(test)]
mod test {
    use super::{GraphNetwork, HypersyncNetwork};
    use crate::config_parsing::chain_helpers::Network;
    use itertools::Itertools;
    use pretty_assertions::assert_eq;
    use serde::Deserialize;
    use strum::IntoEnumIterator;

    #[test]
    fn networks_are_defined_in_alphabetical_order() {
        let networks_sorted = Network::iter()
            .map(|n| n.to_string())
            .sorted()
            .collect::<Vec<_>>();
        let networks = Network::iter().map(|n| n.to_string()).collect::<Vec<_>>();
        assert_eq!(
            networks_sorted, networks,
            "Networks should be defined in alphabetical order (sorry to be picky)"
        );
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
                    .expect(format!("Invalid graph network: {}", s).as_str())
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
}
