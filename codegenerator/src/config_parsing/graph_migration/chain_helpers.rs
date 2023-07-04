use serde::{Deserialize, Serialize};

#[derive(Debug, Deserialize, Serialize)]
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
pub fn get_graph_protocol_chain_id(network_name: Option<NetworkName>) -> i32 {
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
        // placeholder chain ID of 0 for unknown networks for subgraph migration
        None => 0,
    }
}
