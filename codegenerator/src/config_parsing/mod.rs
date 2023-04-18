use std::error::Error;

pub mod entity_parsing;
pub mod event_parsing;

use serde::{Deserialize, Serialize};

use ethereum_abi::Abi;

use crate::capitalization::{Capitalize, CapitalizedOptions};

type NetworkId = i32;

#[derive(Debug, Serialize, Deserialize, Clone, PartialEq)]
struct RequiredEntity {
    name: String,
    labels: Vec<String>,
}

#[derive(Debug, Serialize, Deserialize, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
struct Event {
    name: String,
    required_entities: Option<Vec<RequiredEntity>>,
}

#[derive(Debug, Serialize, Deserialize, Clone, PartialEq)]
struct Network {
    id: NetworkId,
    rpc_url: String,
    start_block: i32,
    contracts: Vec<ConfigContract>,
}

#[derive(Debug, Serialize, Deserialize, Clone, PartialEq)]
pub struct ConfigContract {
    name: String,
    // Eg for implementing a custom deserializer
    //  #[serde(deserialize_with = "abi_path_to_abi")]
    abi_file_path: String,
    handler: Option<String>,
    address: Vec<String>,
    events: Vec<Event>,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct Config {
    version: String,
    description: String,
    repository: String,
    networks: Vec<Network>,
}

// fn abi_path_to_abi<'de, D>(deserializer: D) -> Result<u64, D::Error>
// where
//     D: Deserializer<'de>,
// {
//     let abi_file_path: &str = Deserialize::deserialize(deserializer)?;
//     // ... convert to abi herer
// }

type StringifiedAbi = String;
#[derive(Debug, Serialize, Deserialize, Clone, PartialEq)]
struct SingleContractTemplate {
    name: CapitalizedOptions,
    abi: StringifiedAbi,
    address: String,
    events: Vec<CapitalizedOptions>,
}

#[derive(Debug, Serialize, PartialEq, Clone)]
pub struct ChainConfigTemplate {
    network_config: Network,
    contracts: Vec<SingleContractTemplate>,
}

pub fn get_config_from_yaml(project_root_path: &str) -> Result<Config, Box<dyn Error>> {
    let config_dir = format!("{}/{}", project_root_path, "config.yaml");

    let config = std::fs::read_to_string(&config_dir)?;

    let deserialized_yaml: Config = serde_yaml::from_str(&config)?;
    Ok(deserialized_yaml)
}

pub fn convert_config_to_chain_configs(
    config: &Config,
    project_root_path: &str,
) -> Result<Vec<ChainConfigTemplate>, Box<dyn Error>> {
    let mut chain_configs = Vec::new();
    for network in config.networks.iter() {
        let mut single_contracts = Vec::new();

        for contract in network.contracts.iter() {
            for contract_address in contract.address.iter() {
                let parsed_abi: Abi = event_parsing::get_abi_from_file_path(
                    format!("{}/{}", project_root_path, contract.abi_file_path).as_str(),
                )?;
                let stringified_abi = serde_json::to_string(&parsed_abi)?;
                let single_contract = SingleContractTemplate {
                    name: contract.name.to_capitalized_options(),
                    abi: stringified_abi,
                    address: contract_address.clone(),
                    events: contract
                        .events
                        .iter()
                        .map(|event| event.name.to_capitalized_options())
                        .collect(),
                };
                single_contracts.push(single_contract);
            }
        }

        let chain_config = ChainConfigTemplate {
            network_config: network.clone(),
            contracts: single_contracts,
        };
        chain_configs.push(chain_config);
    }
    Ok(chain_configs)
}

#[cfg(test)]
mod tests {
    use crate::capitalization::Capitalize;

    use super::ChainConfigTemplate;

    use std::fs;

    #[test]
    fn convert_to_chain_configs_case_1() {
        let address1 = String::from("0x2E645469f354BB4F5c8a05B3b30A929361cf77eC");
        let abi_file_path = String::from("test/abi/Contract1.json");

        let event1 = super::Event {
            name: String::from("NewGravatar"),
            required_entities: None,
        };

        let event2 = super::Event {
            name: String::from("UpdateGravatar"),
            required_entities: None,
        };

        let contract1 = super::ConfigContract {
            handler: None,
            address: vec![address1.clone()],
            name: String::from("Contract1"),
            abi_file_path: abi_file_path.clone(),
            events: vec![event1.clone(), event2.clone()],
        };

        let contracts = vec![contract1.clone()];
        let network1 = super::Network {
            id: 1,
            rpc_url: String::from("https://eth.com"),
            start_block: 0,
            contracts,
        };

        let networks = vec![network1.clone()];

        let config = super::Config {
            version: String::from("1.0.0"),
            description: String::from("Test Scenario 1"),
            repository: String::from("github.indexer.com"),
            networks,
        };

        let chain_configs = super::convert_config_to_chain_configs(&config, "dummy path").unwrap();
        let abi = fs::read_to_string(abi_file_path).expect("expected json file to be at this path");
        let single_contract1 = super::SingleContractTemplate {
            name: String::from("Contract1").to_capitalized_options(),
            abi,
            address: address1.clone(),
            events: vec![
                event1.name.to_capitalized_options(),
                event2.name.to_capitalized_options(),
            ],
        };

        let chain_config_1 = ChainConfigTemplate {
            network_config: network1,
            contracts: vec![single_contract1],
        };

        let expected_chain_configs = vec![chain_config_1];

        assert_eq!(chain_configs, expected_chain_configs);
    }

    #[test]
    fn convert_to_chain_configs_case_2() {
        let address1 = String::from("0x2E645469f354BB4F5c8a05B3b30A929361cf77eC");
        let address2 = String::from("0x1E645469f354BB4F5c8a05B3b30A929361cf77eC");

        let abi_file_path = String::from("test/abi/Contract1.json");

        let event1 = super::Event {
            name: String::from("NewGravatar"),
            required_entities: None,
        };

        let event2 = super::Event {
            name: String::from("UpdateGravatar"),
            required_entities: None,
        };

        let contract1 = super::ConfigContract {
            handler: None,
            address: vec![address1.clone()],
            name: String::from("Contract1"),
            abi_file_path: abi_file_path.clone(),
            events: vec![event1.clone(), event2.clone()],
        };

        let contracts1 = vec![contract1.clone()];

        let network1 = super::Network {
            id: 1,
            rpc_url: String::from("https://eth.com"),
            start_block: 0,
            contracts: contracts1,
        };
        let contract2 = super::ConfigContract {
            handler: None,
            address: vec![address2.clone()],
            name: String::from("Contract1"),
            abi_file_path: abi_file_path.clone(),
            events: vec![event1.clone(), event2.clone()],
        };

        let contracts2 = vec![contract2];

        let network2 = super::Network {
            id: 2,
            rpc_url: String::from("https://eth.com"),
            start_block: 0,
            contracts: contracts2,
        };

        let networks = vec![network1.clone(), network2.clone()];

        let config = super::Config {
            version: String::from("1.0.0"),
            description: String::from("Test Scenario 1"),
            repository: String::from("github.indexer.com"),
            networks,
        };

        let chain_configs = super::convert_config_to_chain_configs(&config, ".").unwrap();

        let events = vec![
            event1.name.to_capitalized_options(),
            event2.name.to_capitalized_options(),
        ];

        let abi = fs::read_to_string(abi_file_path).expect("expected json file to be at this path");
        let single_contract1 = super::SingleContractTemplate {
            name: String::from("Contract1").to_capitalized_options(),
            abi: abi.clone(),
            address: address1.clone(),
            events: events.clone(),
        };
        let single_contract2 = super::SingleContractTemplate {
            name: String::from("Contract1").to_capitalized_options(),
            abi,
            address: address2.clone(),
            events,
        };

        let chain_config_1 = ChainConfigTemplate {
            network_config: network1,
            contracts: vec![single_contract1],
        };
        let chain_config_2 = ChainConfigTemplate {
            network_config: network2,
            contracts: vec![single_contract2],
        };

        let expected_chain_configs = vec![chain_config_1, chain_config_2];

        assert_eq!(chain_configs, expected_chain_configs);
    }
}
