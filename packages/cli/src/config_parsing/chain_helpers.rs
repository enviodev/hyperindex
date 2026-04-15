use anyhow::anyhow;

use clap::ValueEnum;
use serde::{Deserialize, Serialize};
use std::fmt;
use strum::IntoEnumIterator;
use subenum::subenum;

#[derive(strum::Display)]
#[subenum(NetworkWithExplorer, HypersyncChain, GraphNetwork)]
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
    #[subenum(HypersyncChain)]
    Ab = 36888,

    #[subenum(HypersyncChain, NetworkWithExplorer)]
    Abstract = 2741,

    #[subenum(HypersyncChain, NetworkWithExplorer)]
    Amoy = 80002,

    #[subenum(GraphNetwork)]
    ArbitrumGoerli = 421613,

    #[subenum(HypersyncChain, NetworkWithExplorer)]
    ArbitrumNova = 42170,

    #[subenum(HypersyncChain, NetworkWithExplorer, GraphNetwork)]
    ArbitrumOne = 42161,

    #[subenum(HypersyncChain, NetworkWithExplorer, GraphNetwork)]
    ArbitrumSepolia = 421614,

    #[subenum(NetworkWithExplorer)]
    ArbitrumTestnet = 421611,

    #[subenum(HypersyncChain)]
    ArcTestnet = 5042002,

    #[subenum(HypersyncChain, GraphNetwork, NetworkWithExplorer)]
    Aurora = 1313161554,

    #[subenum(GraphNetwork, NetworkWithExplorer)]
    AuroraTestnet = 1313161555,

    AuroraTurbo = 1313161567,

    #[subenum(HypersyncChain, GraphNetwork, NetworkWithExplorer)]
    Avalanche = 43114,

    #[subenum(NetworkWithExplorer)]
    B2Testnet = 1123,

    #[subenum(HypersyncChain, NetworkWithExplorer, GraphNetwork)]
    Base = 8453,

    #[subenum(GraphNetwork(serde(rename = "base-testnet")))]
    BaseGoerli = 84531,

    #[subenum(HypersyncChain, NetworkWithExplorer)]
    BaseSepolia = 84532,

    #[subenum(HypersyncChain, NetworkWithExplorer)]
    Berachain = 80094,

    BerachainBartio = 80084,

    #[subenum(HypersyncChain, NetworkWithExplorer)]
    Blast = 81457,

    #[subenum(HypersyncChain, NetworkWithExplorer)]
    BlastSepolia = 168587773,

    #[subenum(HypersyncChain, NetworkWithExplorer)]
    Boba = 288,

    #[subenum(HypersyncChain, NetworkWithExplorer, GraphNetwork)]
    Bsc = 56,

    #[subenum(
        HypersyncChain,
        NetworkWithExplorer,
        GraphNetwork(serde(rename = "chapel"))
    )]
    BscTestnet = 97,

    C1Milkomeda = 2001,

    Canto = 7700,

    #[subenum(HypersyncChain, GraphNetwork, NetworkWithExplorer)]
    Celo = 42220,

    #[subenum(GraphNetwork, NetworkWithExplorer)]
    CeloAlfajores = 44787,

    #[subenum(NetworkWithExplorer)]
    CeloBaklava = 62320,

    ChainwebTestnet20 = 5920,

    ChainwebTestnet21 = 5921,

    ChainwebTestnet22 = 5922,

    ChainwebTestnet23 = 5923,

    ChainwebTestnet24 = 5924,

    #[subenum(HypersyncChain)]
    Chiliz = 88888,

    #[subenum(HypersyncChain)]
    Citrea = 4114,

    CitreaDevnet = 62298,

    #[subenum(HypersyncChain, NetworkWithExplorer)]
    CitreaTestnet = 5115,

    #[subenum(GraphNetwork)]
    Clover = 1023,

    #[subenum(NetworkWithExplorer)]
    Crab = 44,

    #[subenum(HypersyncChain, NetworkWithExplorer)]
    Curtis = 33111,

    #[subenum(HypersyncChain)]
    Cyber = 7560,

    Darwinia = 46,

    #[subenum(
        HypersyncChain,
        NetworkWithExplorer,
        GraphNetwork(serde(rename = "mainnet"))
    )]
    EthereumMainnet = 1,

    #[subenum(NetworkWithExplorer)]
    Evmos = 9001,

    #[subenum(HypersyncChain, NetworkWithExplorer, GraphNetwork)]
    Fantom = 250,

    #[subenum(GraphNetwork, NetworkWithExplorer)]
    FantomTestnet = 4002,

    #[subenum(NetworkWithExplorer)]
    FhenixHelium = 8008135,

    FhenixTestnet = 42069,

    #[subenum(HypersyncChain, NetworkWithExplorer)]
    Flare = 14,

    #[subenum(HypersyncChain, NetworkWithExplorer)]
    Fraxtal = 252,

    #[subenum(HypersyncChain, GraphNetwork, NetworkWithExplorer)]
    Fuji = 43113,

    #[subenum(GraphNetwork)]
    Fuse = 122,

    #[subenum(NetworkWithExplorer)]
    GaladrielDevnet = 696969,

    #[subenum(HypersyncChain, NetworkWithExplorer, GraphNetwork)]
    Gnosis = 100,

    #[subenum(HypersyncChain, NetworkWithExplorer)]
    GnosisChiado = 10200,

    #[subenum(NetworkWithExplorer, GraphNetwork)]
    Goerli = 5,

    #[subenum(HypersyncChain, NetworkWithExplorer)]
    Harmony = 1666600000,

    #[subenum(HypersyncChain, NetworkWithExplorer)]
    Holesky = 17000,

    #[subenum(HypersyncChain, NetworkWithExplorer)]
    Hoodi = 560048,

    #[subenum(HypersyncChain, NetworkWithExplorer)]
    Hyperliquid = 999,

    IncoGentryTestnet = 9090,

    #[subenum(HypersyncChain)]
    Injective = 1776,

    #[subenum(HypersyncChain)]
    Ink = 57073,

    #[subenum(HypersyncChain, NetworkWithExplorer)]
    Kroma = 255,

    #[subenum(HypersyncChain, NetworkWithExplorer)]
    Linea = 59144,

    #[subenum(NetworkWithExplorer)]
    LineaSepolia = 59141,

    #[subenum(HypersyncChain, NetworkWithExplorer)]
    Lisk = 1135,

    #[subenum(HypersyncChain, NetworkWithExplorer)]
    Lukso = 42,

    #[subenum(HypersyncChain, NetworkWithExplorer)]
    LuksoTestnet = 4201,

    #[subenum(HypersyncChain, NetworkWithExplorer)]
    Manta = 169,

    #[subenum(HypersyncChain, NetworkWithExplorer)]
    Mantle = 5000,

    #[subenum(NetworkWithExplorer)]
    MantleTestnet = 5001,

    #[subenum(HypersyncChain)]
    Megaeth = 4326,

    #[subenum(HypersyncChain, NetworkWithExplorer)]
    MegaethTestnet = 6342,

    #[subenum(HypersyncChain, NetworkWithExplorer)]
    MegaethTestnet2 = 6343,

    #[subenum(HypersyncChain)]
    Merlin = 4200,

    #[subenum(HypersyncChain)]
    Metall2 = 1750,

    #[subenum(NetworkWithExplorer)]
    Metis = 1088,

    MevCommit = 17864,

    #[subenum(HypersyncChain, NetworkWithExplorer)]
    Mode = 34443,

    #[subenum(NetworkWithExplorer)]
    ModeSepolia = 919,

    #[subenum(HypersyncChain, NetworkWithExplorer)]
    Monad = 143,

    #[subenum(NetworkWithExplorer, HypersyncChain)]
    MonadTestnet = 10143,

    #[subenum(NetworkWithExplorer, GraphNetwork(serde(rename = "mbase")))]
    MoonbaseAlpha = 1287,

    #[subenum(HypersyncChain, NetworkWithExplorer, GraphNetwork)]
    Moonbeam = 1284,

    #[subenum(GraphNetwork, NetworkWithExplorer)]
    Moonriver = 1285,

    #[subenum(HypersyncChain, NetworkWithExplorer)]
    Morph = 2818,

    #[subenum(NetworkWithExplorer)]
    MorphTestnet = 2810,

    MosaicMatrix = 41454,

    #[subenum(GraphNetwork)]
    Mumbai = 80001,

    #[subenum(NetworkWithExplorer)]
    NeonEvm = 245022934,

    #[subenum(HypersyncChain, NetworkWithExplorer)]
    Opbnb = 204,

    #[subenum(HypersyncChain, NetworkWithExplorer, GraphNetwork)]
    Optimism = 10,

    #[subenum(GraphNetwork)]
    OptimismGoerli = 420,

    #[subenum(HypersyncChain, NetworkWithExplorer)]
    OptimismSepolia = 11155420,

    PharosDevnet = 50002,

    #[subenum(HypersyncChain, NetworkWithExplorer)]
    Plasma = 9745,

    #[subenum(HypersyncChain)]
    Plume = 98866,

    #[subenum(GraphNetwork, NetworkWithExplorer)]
    PoaCore = 99,

    #[subenum(GraphNetwork, NetworkWithExplorer)]
    PoaSokol = 77,

    #[subenum(
        HypersyncChain,
        NetworkWithExplorer,
        GraphNetwork(serde(rename = "matic"))
    )]
    Polygon = 137,

    #[subenum(GraphNetwork, HypersyncChain, NetworkWithExplorer)]
    PolygonZkevm = 1101,

    #[subenum(GraphNetwork, NetworkWithExplorer)]
    PolygonZkevmTestnet = 1442,

    #[subenum(GraphNetwork)]
    Rinkeby = 4,

    #[subenum(HypersyncChain, NetworkWithExplorer)]
    Rsk = 30,

    #[subenum(HypersyncChain, NetworkWithExplorer)]
    Saakuru = 7225878,

    #[subenum(GraphNetwork, HypersyncChain, NetworkWithExplorer)]
    Scroll = 534352,

    #[subenum(GraphNetwork, NetworkWithExplorer)]
    ScrollSepolia = 534351,

    #[subenum(HypersyncChain, NetworkWithExplorer)]
    Sei = 1329,

    #[subenum(HypersyncChain, NetworkWithExplorer)]
    SeiTestnet = 1328,

    #[subenum(HypersyncChain, NetworkWithExplorer, GraphNetwork)]
    Sepolia = 11155111,

    #[subenum(HypersyncChain, NetworkWithExplorer)]
    ShimmerEvm = 148,

    #[subenum(HypersyncChain)]
    Soneium = 1868,

    #[subenum(HypersyncChain, NetworkWithExplorer)]
    Sonic = 146,

    #[subenum(HypersyncChain, NetworkWithExplorer)]
    SonicTestnet = 14601,

    #[subenum(HypersyncChain, NetworkWithExplorer)]
    Sophon = 50104,

    #[subenum(HypersyncChain, NetworkWithExplorer)]
    SophonTestnet = 531050104,

    #[subenum(HypersyncChain)]
    StatusSepolia = 1660990954,

    #[subenum(HypersyncChain)]
    Superseed = 5330,

    #[subenum(HypersyncChain, NetworkWithExplorer)]
    Swell = 1923,

    #[subenum(NetworkWithExplorer)]
    Taiko = 167000,

    #[subenum(NetworkWithExplorer)]
    Tangle = 5845,

    #[subenum(HypersyncChain)]
    Taraxa = 841,

    #[subenum(HypersyncChain, NetworkWithExplorer)]
    Unichain = 130,

    #[subenum(NetworkWithExplorer)]
    UnichainSepolia = 1301,

    #[subenum(HypersyncChain, NetworkWithExplorer)]
    Worldchain = 480,

    XLayer = 196,

    XLayerTestnet = 195,

    #[subenum(HypersyncChain, NetworkWithExplorer)]
    Xdc = 50,

    #[subenum(HypersyncChain, NetworkWithExplorer)]
    XdcTestnet = 51,

    #[subenum(HypersyncChain, NetworkWithExplorer)]
    Zeta = 7000,

    #[subenum(HypersyncChain)]
    Zircuit = 48900,

    #[subenum(HypersyncChain, NetworkWithExplorer, GraphNetwork)]
    ZksyncEra = 324,

    #[subenum(GraphNetwork)]
    ZksyncEraTestnet = 280,

    #[subenum(HypersyncChain, NetworkWithExplorer)]
    Zora = 7777777,

    #[subenum(NetworkWithExplorer)]
    ZoraSepolia = 999999999,
}

impl Network {
    pub fn get_network_id(&self) -> u64 {
        *self as u64
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

    //TODO: research a sufficient threshold for all chains (some should be 0)
    pub fn get_max_reorg_depth(&self) -> Option<u32> {
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
            | Network::OptimismSepolia => Some(0),
            //TODO: research a sufficient threshold for all chains
            Network::Amoy
            | Network::Aurora
            | Network::AuroraTestnet
            | Network::AuroraTurbo
            | Network::Avalanche
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
            | Network::ChainwebTestnet20
            | Network::ChainwebTestnet21
            | Network::ChainwebTestnet22
            | Network::ChainwebTestnet23
            | Network::ChainwebTestnet24
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
            | Network::Plasma
            | Network::Plume
            | Network::Rinkeby
            | Network::Rsk
            | Network::Scroll
            | Network::ScrollSepolia
            | Network::Sei
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
            | Network::MonadTestnet
            | Network::Monad
            | Network::MosaicMatrix
            | Network::Unichain
            | Network::Xdc
            | Network::XdcTestnet
            | Network::Abstract
            | Network::Ab
            | Network::ArcTestnet
            | Network::Hyperliquid
            | Network::PharosDevnet
            | Network::Superseed
            | Network::MegaethTestnet
            | Network::MegaethTestnet2
            | Network::Curtis
            | Network::Worldchain
            | Network::Sonic
            | Network::SonicTestnet
            | Network::Swell
            | Network::Taraxa
            | Network::Citrea
            | Network::Hoodi
            | Network::Injective
            | Network::Megaeth
            | Network::SeiTestnet
            | Network::StatusSepolia => None,
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
    #[serde(alias = "HIDDEN", alias = "EXPERIMENTAL")]
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

impl HypersyncChain {
    // This is a custom iterator that returns all the HypersyncChain enums that is made public accross crates (for convenience)
    pub fn iter_hypersync_chains() -> impl Iterator<Item = HypersyncChain> {
        HypersyncChain::iter()
    }
    pub fn get_tier(&self) -> ChainTier {
        use ChainTier::*;
        use HypersyncChain::*;
        match self {
            EthereumMainnet | Optimism | MonadTestnet | Monad | Gnosis | Sei | Base => Gold,

            Xdc | Polygon | ArbitrumOne | MegaethTestnet | MegaethTestnet2 | Sonic | Megaeth => {
                Silver
            }

            Linea | Berachain | Blast | Amoy | ZksyncEra | ArbitrumNova | Avalanche | Bsc
            | Taraxa | Plasma | Lukso | CitreaTestnet | Injective | Citrea => Bronze,

            Curtis | PolygonZkevm | Abstract | Zora | Unichain | Aurora | Zeta | Manta | Kroma
            | Flare | Mantle | ShimmerEvm | Boba | Ink | Metall2 | SophonTestnet | BscTestnet
            | Zircuit | Celo | Opbnb | GnosisChiado | LuksoTestnet | BlastSepolia | Holesky
            | OptimismSepolia | Fuji | ArbitrumSepolia | Fraxtal | Soneium | BaseSepolia
            | Merlin | Mode | XdcTestnet | Morph | Harmony | Saakuru | Cyber | Superseed
            | Worldchain | Sophon | Fantom | Sepolia | Rsk | Chiliz | Lisk | Hyperliquid
            | Swell | Moonbeam | Plume | Scroll | Ab | ArcTestnet | SonicTestnet | SeiTestnet
            | Hoodi | StatusSepolia => Stone,
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

impl fmt::Display for HypersyncChain {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.get_pretty_name())
    }
}

impl NetworkWithExplorer {
    pub fn get_pretty_name(&self) -> String {
        let network = Network::from(*self);
        match HypersyncChain::try_from(network) {
            Ok(hypersync_chain) => hypersync_chain.get_pretty_name(),
            Err(_) => network.to_string(),
        }
    }
}

impl fmt::Display for NetworkWithExplorer {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.get_pretty_name())
    }
}

pub fn get_max_reorg_depth_from_id(id: u64) -> Option<u32> {
    Network::from_network_id(id)
        .ok()
        .and_then(|n| n.get_max_reorg_depth())
}

#[cfg(test)]
mod test {
    use super::{GraphNetwork, HypersyncChain};
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
        let names_des: Vec<HypersyncChain> = serde_json::from_str(names).unwrap();
        let expected = vec![HypersyncChain::EthereumMainnet, HypersyncChain::Polygon];
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
                    .unwrap_or_else(|_| panic!("Invalid graph network: {}", s))
            })
            .collect::<Vec<GraphNetwork>>();

        let defined_networks = GraphNetwork::iter().collect::<Vec<_>>();

        for n in defined_networks {
            let included_in_supported_networks = supported_graph_networks.iter().any(|sn| &n == sn);
            assert!(
                included_in_supported_networks,
                "expected {:?} to be included",
                n
            )
        }
    }
}
