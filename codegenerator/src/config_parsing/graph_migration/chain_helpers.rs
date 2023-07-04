use serde::{Deserialize, Serialize};

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all(serialize = "kebab-case", deserialize = "kebab-case"))]
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
    serde_json::from_str(network_name).ok()
}

// Function to return the chain ID of the network based on the network name
pub fn get_graph_protocol_chain_id(network_name: NetworkName) -> Option<i32> {
    match network_name {
        NetworkName::Mainnet => Some(1),
        NetworkName::Goerli => Some(5),
        NetworkName::Optimism => Some(10),
        NetworkName::Bsc => Some(56),
        NetworkName::PoaSokol => Some(77),
        NetworkName::Chapel => Some(97),
        NetworkName::PoaCore => Some(99),
        NetworkName::Gnosis => Some(100),
        NetworkName::Fuse => Some(122),
        NetworkName::Matic => Some(137),
        NetworkName::Fantom => Some(250),
        NetworkName::Zksync2Testnet => Some(280),
        NetworkName::Boba => Some(288),
        NetworkName::OptimismGoerli => Some(420),
        NetworkName::Clover => Some(1023),
        NetworkName::Moonbeam => Some(1284),
        NetworkName::Moonriver => Some(1285),
        NetworkName::Mbase => Some(1287),
        NetworkName::FantomTestnet => Some(4002),
        NetworkName::ArbitrumOne => Some(42161),
        NetworkName::ArbitrumGoerli => Some(421613),
        NetworkName::Celo => Some(42220),
        NetworkName::Fuji => Some(43113),
        NetworkName::Avalanche => Some(43114),
        NetworkName::CeloAlfajores => Some(44787),
        NetworkName::Mumbai => Some(80001),
        NetworkName::Aurora => Some(1313161554),
        NetworkName::AuroraTestnet => Some(1313161555),
        NetworkName::Harmony => Some(1666600000),
        NetworkName::BaseTestnet => Some(84531),
        NetworkName::PolygonZkevm => Some(1101),
        NetworkName::ZksyncEra => Some(324),
        NetworkName::Sepolia => Some(11155111),
    }
}
