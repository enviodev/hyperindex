use anyhow::anyhow;

use clap::ValueEnum;
use serde::{Deserialize, Serialize};
use std::fmt;
use strum::IntoEnumIterator;
use subenum::subenum;

#[derive(strum::Display)]
#[subenum(NetworkWithExplorer, HypersyncChain)]
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

    ArbitrumGoerli = 421613,

    #[subenum(HypersyncChain, NetworkWithExplorer)]
    ArbitrumNova = 42170,

    #[subenum(HypersyncChain, NetworkWithExplorer)]
    ArbitrumOne = 42161,

    #[subenum(HypersyncChain, NetworkWithExplorer)]
    ArbitrumSepolia = 421614,

    #[subenum(NetworkWithExplorer)]
    ArbitrumTestnet = 421611,

    #[subenum(HypersyncChain)]
    Arc = 5042,

    #[subenum(HypersyncChain)]
    ArcTestnet = 5042002,

    #[subenum(HypersyncChain, NetworkWithExplorer)]
    Aurora = 1313161554,

    #[subenum(NetworkWithExplorer)]
    AuroraTestnet = 1313161555,

    AuroraTurbo = 1313161567,

    #[subenum(HypersyncChain, NetworkWithExplorer)]
    Avalanche = 43114,

    #[subenum(NetworkWithExplorer)]
    B2Testnet = 1123,

    #[subenum(HypersyncChain, NetworkWithExplorer)]
    Base = 8453,

    BaseGoerli = 84531,

    #[subenum(HypersyncChain, NetworkWithExplorer)]
    BaseSepolia = 84532,

    #[subenum(HypersyncChain, NetworkWithExplorer)]
    Berachain = 80094,

    BerachainBartio = 80084,

    #[subenum(HypersyncChain, NetworkWithExplorer)]
    Blast = 81457,

    #[subenum(NetworkWithExplorer)]
    BlastSepolia = 168587773,

    #[subenum(HypersyncChain, NetworkWithExplorer)]
    Boba = 288,

    #[subenum(HypersyncChain, NetworkWithExplorer)]
    Bsc = 56,

    #[subenum(HypersyncChain, NetworkWithExplorer)]
    BscTestnet = 97,

    C1Milkomeda = 2001,

    Canto = 7700,

    #[subenum(HypersyncChain, NetworkWithExplorer)]
    Celo = 42220,

    #[subenum(NetworkWithExplorer)]
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

    Clover = 1023,

    #[subenum(NetworkWithExplorer)]
    Crab = 44,

    #[subenum(HypersyncChain, NetworkWithExplorer)]
    Curtis = 33111,

    #[subenum(HypersyncChain)]
    Cyber = 7560,

    Darwinia = 46,

    #[subenum(HypersyncChain, NetworkWithExplorer)]
    EthereumMainnet = 1,

    #[subenum(HypersyncChain, NetworkWithExplorer)]
    Etherlink = 42793,

    #[subenum(NetworkWithExplorer)]
    Evmos = 9001,

    #[subenum(HypersyncChain, NetworkWithExplorer)]
    Fantom = 250,

    #[subenum(NetworkWithExplorer)]
    FantomTestnet = 4002,

    #[subenum(NetworkWithExplorer)]
    FhenixHelium = 8008135,

    FhenixTestnet = 42069,

    #[subenum(HypersyncChain, NetworkWithExplorer)]
    Flare = 14,

    #[subenum(HypersyncChain, NetworkWithExplorer)]
    Fraxtal = 252,

    #[subenum(HypersyncChain, NetworkWithExplorer)]
    Fuji = 43113,

    Fuse = 122,

    #[subenum(NetworkWithExplorer)]
    GaladrielDevnet = 696969,

    #[subenum(HypersyncChain, NetworkWithExplorer)]
    Gnosis = 100,

    #[subenum(HypersyncChain, NetworkWithExplorer)]
    GnosisChiado = 10200,

    #[subenum(NetworkWithExplorer)]
    Goerli = 5,

    #[subenum(HypersyncChain, NetworkWithExplorer)]
    Harmony = 1666600000,

    // HyperSync no longer serves Holesky (17000.hypersync.xyz no longer
    // resolves), so it's not a HypersyncChain. Still resolvable via explorer.
    #[subenum(NetworkWithExplorer)]
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

    #[subenum(HypersyncChain)]
    Katana = 747474,

    // HyperSync no longer serves Kroma (255.hypersync.xyz refuses
    // connections and it's gone from active_chains), so it's not a
    // HypersyncChain. Still resolvable via explorer.
    #[subenum(NetworkWithExplorer)]
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

    #[subenum(NetworkWithExplorer)]
    MoonbaseAlpha = 1287,

    #[subenum(HypersyncChain, NetworkWithExplorer)]
    Moonbeam = 1284,

    #[subenum(NetworkWithExplorer)]
    Moonriver = 1285,

    #[subenum(HypersyncChain, NetworkWithExplorer)]
    Morph = 2818,

    #[subenum(NetworkWithExplorer)]
    MorphTestnet = 2810,

    MosaicMatrix = 41454,

    Mumbai = 80001,

    #[subenum(NetworkWithExplorer)]
    NeonEvm = 245022934,

    #[subenum(HypersyncChain, NetworkWithExplorer)]
    Opbnb = 204,

    #[subenum(HypersyncChain, NetworkWithExplorer)]
    Optimism = 10,

    OptimismGoerli = 420,

    #[subenum(HypersyncChain, NetworkWithExplorer)]
    OptimismSepolia = 11155420,

    PharosDevnet = 50002,

    #[subenum(HypersyncChain, NetworkWithExplorer)]
    Plasma = 9745,

    #[subenum(HypersyncChain)]
    Plume = 98866,

    #[subenum(NetworkWithExplorer)]
    PoaCore = 99,

    #[subenum(NetworkWithExplorer)]
    PoaSokol = 77,

    #[subenum(HypersyncChain, NetworkWithExplorer)]
    Polygon = 137,

    #[subenum(HypersyncChain, NetworkWithExplorer)]
    PolygonZkevm = 1101,

    #[subenum(NetworkWithExplorer)]
    PolygonZkevmTestnet = 1442,

    Pulsechain = 369,

    Rinkeby = 4,

    #[subenum(HypersyncChain, NetworkWithExplorer)]
    Robinhood = 4663,

    #[subenum(HypersyncChain, NetworkWithExplorer)]
    Rsk = 30,

    #[subenum(NetworkWithExplorer)]
    Saakuru = 7225878,

    #[subenum(HypersyncChain, NetworkWithExplorer)]
    Scroll = 534352,

    #[subenum(NetworkWithExplorer)]
    ScrollSepolia = 534351,

    #[subenum(HypersyncChain, NetworkWithExplorer)]
    Sei = 1329,

    #[subenum(HypersyncChain, NetworkWithExplorer)]
    SeiTestnet = 1328,

    Sentient = 6767,

    SentientTestnet = 1184075182,

    #[subenum(HypersyncChain, NetworkWithExplorer)]
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

    #[subenum(HypersyncChain)]
    StablesKinshipGrass = 988,

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
    Tempo = 4217,

    #[subenum(HypersyncChain)]
    Tron = 728126428,

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

    #[subenum(HypersyncChain, NetworkWithExplorer)]
    ZksyncEra = 324,

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
            | Network::Etherlink
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
            | Network::Katana
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
            | Network::Sentient
            | Network::SentientTestnet
            | Network::Sepolia
            | Network::ShimmerEvm
            | Network::Sophon
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
            | Network::Arc
            | Network::ArcTestnet
            | Network::Hyperliquid
            | Network::PharosDevnet
            | Network::Superseed
            | Network::MegaethTestnet2
            | Network::Curtis
            | Network::Worldchain
            | Network::Sonic
            | Network::SonicTestnet
            | Network::Swell
            | Network::Citrea
            | Network::Hoodi
            | Network::Injective
            | Network::Megaeth
            | Network::SeiTestnet
            | Network::StablesKinshipGrass
            | Network::StatusSepolia
            | Network::Tempo
            | Network::Tron
            | Network::Pulsechain
            | Network::Robinhood => None,
        }
    }
}

impl HypersyncChain {
    pub fn iter_hypersync_chains() -> impl Iterator<Item = HypersyncChain> {
        HypersyncChain::iter()
    }

    pub fn get_plain_name(&self) -> String {
        Network::from(*self).to_string()
    }
}

impl fmt::Display for HypersyncChain {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.get_plain_name())
    }
}

impl fmt::Display for NetworkWithExplorer {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", Network::from(*self))
    }
}

pub fn get_max_reorg_depth_from_id(id: u64) -> Option<u32> {
    Network::from_network_id(id)
        .ok()
        .and_then(|n| n.get_max_reorg_depth())
}

#[cfg(test)]
mod test {
    use super::HypersyncChain;
    use crate::config_parsing::chain_helpers::Network;
    use itertools::Itertools;
    use pretty_assertions::assert_eq;
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
    fn arc_mainnet_is_supported_by_hypersync() {
        assert_eq!(
            (
                Network::from_network_id(5042).unwrap().to_string(),
                HypersyncChain::from_repr(5042).is_some()
            ),
            ("arc".to_string(), true)
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
}
