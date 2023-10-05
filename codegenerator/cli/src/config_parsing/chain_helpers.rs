use anyhow::anyhow;
use clap::ValueEnum;
use serde::{Deserialize, Serialize};
use strum_macros::{Display, EnumIter, EnumString};
use subenum::subenum;

#[subenum(NetworkWithExplorer, SupportedNetwork, SkarNetwork, EthArchiveNetwork)]
#[derive(
    Clone,
    Debug,
    ValueEnum,
    Serialize,
    Deserialize,
    EnumIter,
    EnumString,
    PartialEq,
    Eq,
    Display,
    Hash,
)]
#[serde(rename_all = "kebab-case")]
//Please note! The current list is an exhaustive list of the graphs
//chains and what the deserialize to
//If we want to expand this list to incorporate other networks that we use,
//pleaes add a subenum for the graph and add the attribute to each value here
//If we want to change the names of any of these for our own use then we need
//custom deserializers for the graph
pub enum NetworkName {
    #[subenum(SupportedNetwork, NetworkWithExplorer, SkarNetwork)]
    Mainnet,
    #[subenum(SupportedNetwork, NetworkWithExplorer, SkarNetwork)]
    Goerli,
    #[subenum(SupportedNetwork, NetworkWithExplorer, EthArchiveNetwork)]
    Optimism,
    #[subenum(SupportedNetwork, NetworkWithExplorer, EthArchiveNetwork, SkarNetwork)]
    Bsc,
    PoaSokol,
    Chapel,
    PoaCore,
    #[subenum(SupportedNetwork, SkarNetwork)]
    Gnosis,
    Fuse,
    Fantom,
    #[subenum(SupportedNetwork, NetworkWithExplorer, SkarNetwork, EthArchiveNetwork)]
    Matic,
    Zksync2Testnet,
    Boba,
    #[subenum(NetworkWithExplorer)]
    OptimismGoerli,
    Clover,
    Moonbeam,
    Moonriver,
    Mbase,
    FantomTestnet,
    #[subenum(SupportedNetwork, NetworkWithExplorer, EthArchiveNetwork)]
    ArbitrumOne,
    #[subenum(NetworkWithExplorer)]
    ArbitrumGoerli,
    Celo,
    Fuji,
    #[subenum(SupportedNetwork, NetworkWithExplorer, EthArchiveNetwork)]
    Avalanche,
    CeloAlfajores,
    #[subenum(NetworkWithExplorer)]
    Mumbai,
    Aurora,
    AuroraTestnet,
    Harmony,
    #[subenum(SupportedNetwork, EthArchiveNetwork)]
    BaseTestnet,
    MaticZkevm,
    ZksyncEra,
    #[subenum(NetworkWithExplorer, SkarNetwork)]
    Sepolia,
    #[subenum(SupportedNetwork, EthArchiveNetwork, SkarNetwork)]
    Linea,
}

// Function to return the chain ID of the network based on the network name
pub fn get_network_id_given_network_name(network_name: NetworkName) -> i32 {
    match network_name {
        NetworkName::Mainnet => 1,
        NetworkName::Goerli => 5,
        NetworkName::Optimism => 10,
        NetworkName::Bsc => 56,
        NetworkName::PoaSokol => 77,
        NetworkName::Chapel => 97,
        NetworkName::PoaCore => 99,
        NetworkName::Gnosis => 100,
        NetworkName::Fuse => 122,
        NetworkName::Matic => 137,
        NetworkName::Fantom => 250,
        NetworkName::Zksync2Testnet => 280,
        NetworkName::Boba => 288,
        NetworkName::OptimismGoerli => 420,
        NetworkName::Clover => 1023,
        NetworkName::Moonbeam => 1284,
        NetworkName::Moonriver => 1285,
        NetworkName::Mbase => 1287,
        NetworkName::FantomTestnet => 4002,
        NetworkName::ArbitrumOne => 42161,
        NetworkName::ArbitrumGoerli => 421613,
        NetworkName::Celo => 42220,
        NetworkName::Fuji => 43113,
        NetworkName::Avalanche => 43114,
        NetworkName::CeloAlfajores => 44787,
        NetworkName::Mumbai => 80001,
        NetworkName::Aurora => 1313161554,
        NetworkName::AuroraTestnet => 1313161555,
        NetworkName::Harmony => 1666600000,
        NetworkName::BaseTestnet => 84531,
        NetworkName::MaticZkevm => 1101,
        NetworkName::ZksyncEra => 324,
        NetworkName::Sepolia => 11155111,
        NetworkName::Linea => 59144,
    }
}

// Function to return the chain ID of the network based on the network name
pub fn get_network_name_from_id(network_id: i32) -> anyhow::Result<NetworkName> {
    let network_name = match network_id {
        1 => NetworkName::Mainnet,
        5 => NetworkName::Goerli,
        10 => NetworkName::Optimism,
        56 => NetworkName::Bsc,
        77 => NetworkName::PoaSokol,
        97 => NetworkName::Chapel,
        99 => NetworkName::PoaCore,
        100 => NetworkName::Gnosis,
        122 => NetworkName::Fuse,
        137 => NetworkName::Matic,
        250 => NetworkName::Fantom,
        280 => NetworkName::Zksync2Testnet,
        288 => NetworkName::Boba,
        420 => NetworkName::OptimismGoerli,
        1023 => NetworkName::Clover,
        1284 => NetworkName::Moonbeam,
        1285 => NetworkName::Moonriver,
        1287 => NetworkName::Mbase,
        4002 => NetworkName::FantomTestnet,
        42161 => NetworkName::ArbitrumOne,
        421613 => NetworkName::ArbitrumGoerli,
        42220 => NetworkName::Celo,
        43113 => NetworkName::Fuji,
        43114 => NetworkName::Avalanche,
        44787 => NetworkName::CeloAlfajores,
        80001 => NetworkName::Mumbai,
        1313161554 => NetworkName::Aurora,
        1313161555 => NetworkName::AuroraTestnet,
        1666600000 => NetworkName::Harmony,
        84531 => NetworkName::BaseTestnet,
        1101 => NetworkName::MaticZkevm,
        324 => NetworkName::ZksyncEra,
        11155111 => NetworkName::Sepolia,
        59144 => NetworkName::Linea,
        _ => Err(anyhow!(format!(
            "Failed converting network_id {} to network name",
            network_id
        )))?,
    };
    Ok(network_name)
}

// Function to return the chain ID of the network based on the network name
pub fn get_base_url_for_explorer(network_name: &NetworkWithExplorer) -> String {
    match network_name {
        NetworkWithExplorer::Mainnet => "api.etherscan.io".to_string(),
        NetworkWithExplorer::Goerli => "api-goerli.etherscan.io".to_string(),
        NetworkWithExplorer::Optimism => "api-optimistic.etherscan.io".to_string(),
        NetworkWithExplorer::Bsc => "api.bscscan.com".to_string(),
        NetworkWithExplorer::Matic => "api.polygonscan.com".to_string(),
        NetworkWithExplorer::OptimismGoerli => "api-goerli-optimistic.etherscan.io".to_string(),
        NetworkWithExplorer::ArbitrumOne => "api.arbiscan.io".to_string(),
        NetworkWithExplorer::ArbitrumGoerli => "api-goerli.arbiscan.io".to_string(),
        NetworkWithExplorer::Avalanche => "api.snowtrace.io".to_string(),
        NetworkWithExplorer::Mumbai => "api-testnet.polygonscan.com".to_string(),
        NetworkWithExplorer::Sepolia => "api-sepolia.etherscan.io".to_string(),
    }
}

// Function to return the API key for the explorer based on network name
pub fn get_api_key_for_explorer(network_name: &NetworkWithExplorer) -> String {
    match network_name {
        NetworkWithExplorer::Mainnet => "WR5JNQKI5HJ8EP9EGCBY544AH8Y6G8KFZV".to_string(),
        NetworkWithExplorer::Goerli => "WR5JNQKI5HJ8EP9EGCBY544AH8Y6G8KFZV".to_string(),
        NetworkWithExplorer::Optimism => "Z1A9EP3DSM9SNZ2IDMAVPPGYDDG6FRYINA".to_string(),
        NetworkWithExplorer::Bsc => "api.bscscan.com".to_string(),
        NetworkWithExplorer::Matic => "I9CKKRUZBHCI1TWN8R44EIUBY6U2GI48FP".to_string(),
        NetworkWithExplorer::OptimismGoerli => "Z1A9EP3DSM9SNZ2IDMAVPPGYDDG6FRYINA".to_string(),
        NetworkWithExplorer::ArbitrumOne => "1W3AF7G7TRTGSPASM11SHZSIZRII5EX92D".to_string(),
        NetworkWithExplorer::ArbitrumGoerli => "1W3AF7G7TRTGSPASM11SHZSIZRII5EX92D".to_string(),
        NetworkWithExplorer::Avalanche => "EJZP7RY157YUI981Q6DMHFZ24U2ET8EHCK".to_string(),
        NetworkWithExplorer::Mumbai => "I9CKKRUZBHCI1TWN8R44EIUBY6U2GI48FP".to_string(),
        NetworkWithExplorer::Sepolia => "WR5JNQKI5HJ8EP9EGCBY544AH8Y6G8KFZV".to_string(),
    }
}

#[cfg(test)]
mod test {

    use super::{get_network_id_given_network_name, get_network_name_from_id, NetworkName};

    use anyhow::Context;
    use strum::IntoEnumIterator;

    #[test]
    fn all_network_names_have_a_chain_id_mapping() {
        for network in NetworkName::iter() {
            let chain_id = get_network_id_given_network_name(network.clone().into());

            let converted_network = get_network_name_from_id(chain_id)
                .context("Testing all networks have a chain id converter")
                .unwrap();

            assert_eq!(&converted_network, &network);
        }
    }
}
