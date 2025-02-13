use anyhow::anyhow;

use clap::ValueEnum;
use serde::{Deserialize, Serialize};
use std::fmt;
use strum::IntoEnumIterator;
use subenum::subenum;

use crate::constants::DEFAULT_CONFIRMED_BLOCK_THRESHOLD;

#[derive(strum::Display)]
#[subenum(NetworkWithExplorer, HypersyncNetwork, GraphNetwork)]
#[derive(
    Clone,
    Debug,
    ValueEnum,
    Serialize,
    Deserialize,
    strum::EnumIter,
    strum::EnumString,
    strum::FromRepr,
    PartialEq,
    Eq,
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

    #[subenum(HypersyncNetwork, GraphNetwork, NetworkWithExplorer)]
    Aurora = 1313161554,

    #[subenum(GraphNetwork, NetworkWithExplorer)]
    AuroraTestnet = 1313161555,

    #[subenum(HypersyncNetwork, GraphNetwork, NetworkWithExplorer)]
    Avalanche = 43114,

    #[subenum(NetworkWithExplorer)]
    B2Testnet = 1123,

    #[subenum(HypersyncNetwork, NetworkWithExplorer, GraphNetwork)]
    Base = 8453,

    #[subenum(GraphNetwork(serde(rename = "base-testnet")))]
    BaseGoerli = 84531,

    #[subenum(HypersyncNetwork, NetworkWithExplorer)]
    BaseSepolia = 84532,

    #[subenum(HypersyncNetwork)]
    Berachain = 80094,

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

    C1Milkomeda = 2001,

    Canto = 7700,

    #[subenum(HypersyncNetwork, GraphNetwork, NetworkWithExplorer)]
    Celo = 42220,

    #[subenum(GraphNetwork, NetworkWithExplorer)]
    CeloAlfajores = 44787,

    #[subenum(NetworkWithExplorer)]
    CeloBaklava = 62320,

    #[subenum(HypersyncNetwork)]
    Chiliz = 8888,

    CitreaDevnet = 62298,

    #[subenum(HypersyncNetwork, NetworkWithExplorer)]
    CitreaTestnet = 5115,

    #[subenum(GraphNetwork)]
    Clover = 1023,

    #[subenum(HypersyncNetwork, NetworkWithExplorer)]
    Crab = 44,

    #[subenum(HypersyncNetwork)]
    Cyber = 7560,

    #[subenum(HypersyncNetwork)]
    Darwinia = 46,

    #[subenum(
        HypersyncNetwork,
        NetworkWithExplorer,
        GraphNetwork(serde(rename = "mainnet"))
    )]
    EthereumMainnet = 1,

    #[subenum(NetworkWithExplorer)]
    Evmos = 9001,

    #[subenum(HypersyncNetwork, NetworkWithExplorer, GraphNetwork)]
    Fantom = 250,

    #[subenum(GraphNetwork, NetworkWithExplorer)]
    FantomTestnet = 4002,

    #[subenum(NetworkWithExplorer)]
    FhenixHelium = 8008135,

    FhenixTestnet = 42069,

    #[subenum(HypersyncNetwork, NetworkWithExplorer)]
    Flare = 14,

    #[subenum(HypersyncNetwork)]
    Fraxtal = 252,

    #[subenum(HypersyncNetwork, GraphNetwork, NetworkWithExplorer)]
    Fuji = 43113,

    #[subenum(GraphNetwork)]
    Fuse = 122,

    #[subenum(
        HypersyncNetwork(serde(rename = "galadriel-devnet (Stone)")),
        NetworkWithExplorer
    )]
    GaladrielDevnet = 696969,

    #[subenum(HypersyncNetwork, NetworkWithExplorer, GraphNetwork)]
    Gnosis = 100,

    #[subenum(HypersyncNetwork, NetworkWithExplorer)]
    GnosisChiado = 10200,

    #[subenum(HypersyncNetwork, NetworkWithExplorer, GraphNetwork)]
    Goerli = 5,

    #[subenum(HypersyncNetwork, NetworkWithExplorer)]
    Harmony = 1666600000,

    #[subenum(HypersyncNetwork, NetworkWithExplorer)]
    Holesky = 17000,

    IncoGentryTestnet = 9090,

    #[subenum(HypersyncNetwork)]
    Ink = 57073,

    #[subenum(HypersyncNetwork, NetworkWithExplorer)]
    Kroma = 255,

    #[subenum(HypersyncNetwork, NetworkWithExplorer)]
    Linea = 59144,

    #[subenum(NetworkWithExplorer)]
    LineaSepolia = 59141,

    #[subenum(HypersyncNetwork, NetworkWithExplorer)]
    Lisk = 1135,

    #[subenum(HypersyncNetwork, NetworkWithExplorer)]
    Lukso = 42,

    #[subenum(HypersyncNetwork, NetworkWithExplorer)]
    LuksoTestnet = 4201,

    #[subenum(HypersyncNetwork, NetworkWithExplorer)]
    Manta = 169,

    #[subenum(HypersyncNetwork, NetworkWithExplorer)]
    Mantle = 5000,

    #[subenum(NetworkWithExplorer)]
    MantleTestnet = 5001,

    #[subenum(HypersyncNetwork)]
    Merlin = 4200,

    #[subenum(HypersyncNetwork)]
    Metall2 = 1750,

    #[subenum(HypersyncNetwork, NetworkWithExplorer)]
    Metis = 1088,

    #[subenum(HypersyncNetwork)]
    MevCommit = 17864,

    #[subenum(HypersyncNetwork, NetworkWithExplorer)]
    Mode = 34443,

    #[subenum(NetworkWithExplorer)]
    ModeSepolia = 919,

    #[subenum(HypersyncNetwork)]
    MonadTestnet = 41454,

    #[subenum(
        HypersyncNetwork,
        NetworkWithExplorer,
        GraphNetwork(serde(rename = "mbase"))
    )]
    MoonbaseAlpha = 1287,

    #[subenum(HypersyncNetwork, NetworkWithExplorer, GraphNetwork)]
    Moonbeam = 1284,

    #[subenum(GraphNetwork, NetworkWithExplorer)]
    Moonriver = 1285,

    #[subenum(HypersyncNetwork, NetworkWithExplorer)]
    Morph = 2818,

    #[subenum(HypersyncNetwork, NetworkWithExplorer)]
    MorphTestnet = 2810,

    #[subenum(GraphNetwork)]
    Mumbai = 80001,

    #[subenum(HypersyncNetwork, NetworkWithExplorer)]
    NeonEvm = 245022934,

    #[subenum(HypersyncNetwork, NetworkWithExplorer)]
    Opbnb = 204,

    #[subenum(HypersyncNetwork, NetworkWithExplorer, GraphNetwork)]
    Optimism = 10,

    #[subenum(GraphNetwork)]
    OptimismGoerli = 420,

    #[subenum(HypersyncNetwork, NetworkWithExplorer)]
    OptimismSepolia = 11155420,

    #[subenum(GraphNetwork, NetworkWithExplorer)]
    PoaCore = 99,

    #[subenum(GraphNetwork, NetworkWithExplorer)]
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

    #[subenum(HypersyncNetwork, NetworkWithExplorer)]
    Rsk = 30,

    #[subenum(HypersyncNetwork, NetworkWithExplorer)]
    Saakuru = 7225878,

    #[subenum(GraphNetwork, HypersyncNetwork, NetworkWithExplorer)]
    Scroll = 534352,

    #[subenum(GraphNetwork, NetworkWithExplorer)]
    ScrollSepolia = 534351,

    #[subenum(HypersyncNetwork, NetworkWithExplorer, GraphNetwork)]
    Sepolia = 11155111,

    #[subenum(HypersyncNetwork, NetworkWithExplorer)]
    ShimmerEvm = 148,

    #[subenum(HypersyncNetwork)]
    Soneium = 1868,

    #[subenum(HypersyncNetwork)]
    Sophon = 50104,

    #[subenum(HypersyncNetwork)]
    SophonTestnet = 531050104,

    #[subenum(NetworkWithExplorer)]
    Taiko = 167000,

    #[subenum(NetworkWithExplorer)]
    Tangle = 5845,

    #[subenum(HypersyncNetwork, NetworkWithExplorer)]
    UnichainSepolia = 1301,

    XLayer = 196,

    XLayerTestnet = 195,

    #[subenum(HypersyncNetwork, NetworkWithExplorer)]
    Zeta = 7000,

    #[subenum(HypersyncNetwork)]
    Zircuit = 48900,

    #[subenum(HypersyncNetwork, GraphNetwork)]
    ZksyncEra = 324,

    #[subenum(GraphNetwork)]
    ZksyncEraTestnet = 280,

    #[subenum(HypersyncNetwork, NetworkWithExplorer)]
    Zora = 7777777,

    #[subenum(NetworkWithExplorer)]
    ZoraSepolia = 999999999,
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
            | Network::CitreaTestnet
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
            | Network::Canto
            | Network::Celo
            | Network::CeloAlfajores
            | Network::CeloBaklava
            | Network::Chiliz
            | Network::Clover
            | Network::Crab
            | Network::Cyber
            | Network::Darwinia
            | Network::Evmos
            | Network::EthereumMainnet
            | Network::Fantom
            | Network::FantomTestnet
            | Network::FhenixHelium
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
            | Network::MantleTestnet
            | Network::MevCommit
            | Network::Mode
            | Network::ModeSepolia
            | Network::Metis
            | Network::MoonbaseAlpha
            | Network::Moonbeam
            | Network::Moonriver
            | Network::Mumbai
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
            | Network::Sophon
            | Network::SophonTestnet
            | Network::XLayer
            | Network::XLayerTestnet
            | Network::Zeta
            | Network::Zircuit
            | Network::ZksyncEra
            | Network::ZksyncEraTestnet
            | Network::Zora
            | Network::ZoraSepolia
            | Network::Lisk
            | Network::Taiko
            | Network::LuksoTestnet
            | Network::Merlin
            | Network::B2Testnet
            | Network::UnichainSepolia
            | Network::Opbnb
            | Network::Saakuru
            | Network::Morph
            | Network::MorphTestnet
            | Network::Tangle
            | Network::Fraxtal
            | Network::Soneium
            | Network::Ink
            | Network::Metall2
            | Network::Berachain
            | Network::MonadTestnet => DEFAULT_CONFIRMED_BLOCK_THRESHOLD,
        }
    }
}

#[derive(Deserialize, Debug, PartialEq, strum::Display)]
#[serde(rename_all = "UPPERCASE")]
pub enum ChainTier {
    Gold,
    Silver,
    Bronze,
    #[serde(alias = "TESTNET")]
    Stone,
    #[serde(alias = "HIDDEN")]
    Internal,
}

impl ChainTier {
    pub fn get_icon(&self) -> &str {
        match self {
            Self::Gold => "🥇",
            Self::Silver => "🥈",
            Self::Bronze => "🥉",
            Self::Stone => "🪨",
            Self::Internal => "🔒",
        }
    }

    pub fn is_public(&self) -> bool {
        match self {
            Self::Gold | Self::Silver | Self::Bronze | Self::Stone => true,
            Self::Internal => false,
        }
    }
}

impl HypersyncNetwork {
    // This is a custom iterator that returns all the HypersyncNetwork enums that is made public accross crates (for convenience)
    pub fn iter_hypersync_networks() -> impl Iterator<Item = HypersyncNetwork> {
        HypersyncNetwork::iter()
    }
    pub fn get_tier(&self) -> ChainTier {
        use ChainTier::*;
        use HypersyncNetwork::*;
        match self {
            EthereumMainnet | Fantom | Sepolia | ZksyncEra | Optimism | ArbitrumNova
            | Avalanche | Polygon | Bsc | Gnosis => Gold,

            Linea | Base | Blast | Cyber | Harmony | Scroll | Rsk | Amoy | Saakuru | Moonbeam
            | Lisk | Chiliz | ArbitrumOne => Silver,

            Zora | Morph | Lukso | Sophon | PolygonZkevm => Bronze,

            MonadTestnet | Berachain | Aurora | Zeta | Manta | Kroma | Crab | Flare | Mantle
            | Metis | ShimmerEvm | Darwinia | Boba | Ink | Metall2 | SophonTestnet
            | MorphTestnet | GaladrielDevnet | CitreaTestnet | Goerli | BscTestnet
            | UnichainSepolia | Zircuit | Celo | Opbnb | GnosisChiado | LuksoTestnet
            | BlastSepolia | Holesky | BerachainBartio | OptimismSepolia | Fuji | NeonEvm
            | ArbitrumSepolia | Fraxtal | Soneium | BaseSepolia | MevCommit | Merlin | Mode
            | MoonbaseAlpha => Stone,
        }
    }

    pub fn get_plain_name(&self) -> String {
        Network::from(*self).to_string()
    }

    pub fn get_pretty_name(&self) -> String {
        let name = Network::from(*self).to_string();
        let tier = self.get_tier();
        let icon = tier.get_icon();
        format!("{name} {icon}")
    }
}

impl fmt::Display for HypersyncNetwork {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.get_pretty_name())
    }
}

impl NetworkWithExplorer {
    pub fn get_pretty_name(&self) -> String {
        let network = Network::from(*self);
        match HypersyncNetwork::try_from(network) {
            Ok(hypersync_network) => hypersync_network.get_pretty_name(),
            Err(_) => network.to_string(),
        }
    }
}

impl fmt::Display for NetworkWithExplorer {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.get_pretty_name())
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
