use clap::ValueEnum;
use serde::{Deserialize, Serialize};
use strum_macros::{Display, EnumIter};

#[derive(Clone, Debug, ValueEnum, Serialize, Deserialize, EnumIter, PartialEq, Eq, Display)]
#[serde(rename_all = "kebab-case")]
pub enum NetworkName {
    Mainnet,
    Goerli,
    Optimism,
    Bsc,
    PoaSokol,
    Chapel,
    PoaCore,
    Gnosis,
    Fuse,
    Fantom,
    Matic,
    Zksync2Testnet,
    Boba,
    OptimismGoerli,
    Clover,
    Moonbeam,
    Moonriver,
    Mbase,
    FantomTestnet,
    ArbitrumOne,
    ArbitrumGoerli,
    Celo,
    Fuji,
    Avalanche,
    CeloAlfajores,
    Mumbai,
    Aurora,
    AuroraTestnet,
    Harmony,
    BaseTestnet,
    PolygonZkevm,
    ZksyncEra,
    Sepolia,
}

pub fn deserialize_network_name(network_name: &str) -> Option<NetworkName> {
    serde_json::to_value(network_name)
        .ok()
        .and_then(|value| serde_json::from_value(value).ok())
}

// Function to return the chain ID of the network based on the network name
pub fn get_network_id_given_network_name(network_name: Option<NetworkName>) -> i32 {
    match network_name {
        Some(NetworkName::Mainnet) => 1,
        Some(NetworkName::Goerli) => 5,
        Some(NetworkName::Optimism) => 10,
        Some(NetworkName::Bsc) => 56,
        Some(NetworkName::PoaSokol) => 77,
        Some(NetworkName::Chapel) => 97,
        Some(NetworkName::PoaCore) => 99,
        Some(NetworkName::Gnosis) => 100,
        Some(NetworkName::Fuse) => 122,
        Some(NetworkName::Matic) => 137,
        Some(NetworkName::Fantom) => 250,
        Some(NetworkName::Zksync2Testnet) => 280,
        Some(NetworkName::Boba) => 288,
        Some(NetworkName::OptimismGoerli) => 420,
        Some(NetworkName::Clover) => 1023,
        Some(NetworkName::Moonbeam) => 1284,
        Some(NetworkName::Moonriver) => 1285,
        Some(NetworkName::Mbase) => 1287,
        Some(NetworkName::FantomTestnet) => 4002,
        Some(NetworkName::ArbitrumOne) => 42161,
        Some(NetworkName::ArbitrumGoerli) => 421613,
        Some(NetworkName::Celo) => 42220,
        Some(NetworkName::Fuji) => 43113,
        Some(NetworkName::Avalanche) => 43114,
        Some(NetworkName::CeloAlfajores) => 44787,
        Some(NetworkName::Mumbai) => 80001,
        Some(NetworkName::Aurora) => 1313161554,
        Some(NetworkName::AuroraTestnet) => 1313161555,
        Some(NetworkName::Harmony) => 1666600000,
        Some(NetworkName::BaseTestnet) => 84531,
        Some(NetworkName::PolygonZkevm) => 1101,
        Some(NetworkName::ZksyncEra) => 324,
        Some(NetworkName::Sepolia) => 11155111,
        // placeholder network ID of 0 for unknown networks for subgraph migration
        None => 0,
    }
}

// Function to return the chain ID of the network based on the network name
pub fn get_base_url_for_explorer(network_name: Option<NetworkName>) -> String {
    match network_name {
        Some(NetworkName::Mainnet) => "api.etherscan.io".to_string(),
        Some(NetworkName::Goerli) => "api-goerli.etherscan.io".to_string(),
        Some(NetworkName::Optimism) => "api-optimistic.etherscan.io".to_string(),
        Some(NetworkName::Bsc) => "api.bscscan.com".to_string(),
        Some(NetworkName::PoaSokol) => "".to_string(),
        Some(NetworkName::Chapel) => "".to_string(),
        Some(NetworkName::PoaCore) => "".to_string(),
        Some(NetworkName::Gnosis) => "".to_string(),
        Some(NetworkName::Fuse) => "".to_string(),
        Some(NetworkName::Matic) => "api.polygonscan.com".to_string(),
        Some(NetworkName::Fantom) => "".to_string(),
        Some(NetworkName::Zksync2Testnet) => "".to_string(),
        Some(NetworkName::Boba) => "".to_string(),
        Some(NetworkName::OptimismGoerli) => "api-goerli-optimistic.etherscan.io".to_string(),
        Some(NetworkName::Clover) => "".to_string(),
        Some(NetworkName::Moonbeam) => "".to_string(),
        Some(NetworkName::Moonriver) => "".to_string(),
        Some(NetworkName::Mbase) => "".to_string(),
        Some(NetworkName::FantomTestnet) => "".to_string(),
        Some(NetworkName::ArbitrumOne) => "api.arbiscan.io".to_string(),
        Some(NetworkName::ArbitrumGoerli) => "api-goerli.arbiscan.io".to_string(),
        Some(NetworkName::Celo) => "".to_string(),
        Some(NetworkName::Fuji) => "".to_string(),
        Some(NetworkName::Avalanche) => "api.snowtrace.io".to_string(),
        Some(NetworkName::CeloAlfajores) => "".to_string(),
        Some(NetworkName::Mumbai) => "".to_string(),
        Some(NetworkName::Aurora) => "".to_string(),
        Some(NetworkName::AuroraTestnet) => "".to_string(),
        Some(NetworkName::Harmony) => "".to_string(),
        Some(NetworkName::BaseTestnet) => "".to_string(),
        Some(NetworkName::PolygonZkevm) => "".to_string(),
        Some(NetworkName::ZksyncEra) => "".to_string(),
        Some(NetworkName::Sepolia) => "api-sepolia.etherscan.io".to_string(),
        // placeholder base url of "" for unknown networks for contract migration
        None => "".to_string(),
    }
}
