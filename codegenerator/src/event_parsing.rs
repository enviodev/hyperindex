use std::collections::HashMap;

use crate::{Capitalize, Contract, Error, ParamType, RecordType, CURRENT_DIR_PATH};
use serde::{Deserialize, Serialize};

use serde_yaml;

use ethereum_abi::Abi;

pub fn get_contract_types_from_config() -> Result<Vec<Contract>, Box<dyn Error>> {
    let config_dir = format!("{}/{}", CURRENT_DIR_PATH, "config.yaml");

    let config = std::fs::read_to_string(&config_dir)?;

    let deserialized_yaml: Config = serde_yaml::from_str(&config)?;
    let mut contracts: Vec<Contract> = Vec::new();

    for config_contract in deserialized_yaml.contracts.iter() {
        let mut event_types: Vec<RecordType> = Vec::new();
        let abi_path = format!("{}/{}", CURRENT_DIR_PATH, config_contract.abi);
        let abi_file = std::fs::read_to_string(abi_path)?;
        let contract_abi: Abi = serde_json::from_str(&abi_file).expect("failed to parse abi");
        let events: Vec<ethereum_abi::Event> = contract_abi.events;
        for event in config_contract.events.iter() {
            println!("{}", event.name);
            let event = events
                .iter()
                .find(|&abi_event| abi_event.name == event.name);

            match event {
                Some(event) => {
                    let event_type = RecordType {
                        name: event.name.to_owned().to_capitalized_options(),
                        params: event
                            .inputs
                            .iter()
                            .map(|input| ParamType {
                                key: input.name.to_owned(),
                                type_: match input.type_ {
                                    ethereum_abi::Type::Uint(_size) => "int",
                                    ethereum_abi::Type::Int(_size) => "int",
                                    ethereum_abi::Type::Bool => "bool",
                                    ethereum_abi::Type::Address => "string",
                                    ethereum_abi::Type::Bytes => "string",
                                    ethereum_abi::Type::String => "string",
                                    ethereum_abi::Type::FixedBytes(_) => "type_not_handled",
                                    ethereum_abi::Type::Array(_) => "type_not_handled",
                                    ethereum_abi::Type::FixedArray(_, _) => "type_not_handled",
                                    ethereum_abi::Type::Tuple(_) => "type_not_handled",
                                }
                                .to_owned(),
                            })
                            .collect(),
                    };
                    event_types.push(event_type);
                }
                None => (),
            };
        }
        let contract = Contract {
            name: config_contract.name.to_capitalized_options(),
            address: config_contract.address.clone(),
            events: event_types,
        };
        contracts.push(contract);
    }
    Ok(contracts)
}

type NetworkId = i32;
#[derive(Debug, Serialize, Deserialize, Clone, PartialEq)]
struct Network {
    id: NetworkId,
    rpc_url: String,
    start_block: i32,
}

#[derive(Debug, Serialize, Deserialize, Clone, PartialEq)]
struct ReadEntity {
    name: String,
    labels: Vec<String>,
}
#[derive(Debug, Serialize, Deserialize, Clone, PartialEq)]
struct Event {
    name: String,
    read_entities: Option<Vec<ReadEntity>>,
}

#[derive(Debug, Serialize, Deserialize, Clone, PartialEq)]
struct ConfigContract {
    name: String,
    abi: String,
    address: String,
    networks: Option<Vec<NetworkId>>,
    events: Vec<Event>,
}

#[derive(Debug, Serialize, Deserialize)]
struct Config {
    version: String,
    description: String,
    repository: String,
    networks: Vec<Network>,
    handler: String,
    contracts: Vec<ConfigContract>,
}

#[derive(Debug, PartialEq)]
struct ChainConfig {
    network_config: Network,
    contracts: Vec<ConfigContract>,
}

fn convert_config_to_chain_configs(config: &Config) -> Vec<ChainConfig> {
    let mut network_map: HashMap<NetworkId, ChainConfig> = HashMap::new();

    let mut all_network_ids = Vec::new();

    for network in config.networks.iter() {
        all_network_ids.push(network.id);
        let chain_config = ChainConfig {
            network_config: network.clone(),
            contracts: vec![],
        };

        network_map.insert(network.id, chain_config);
    }
    for contract in config.contracts.iter() {
        let contract_network_ids = match &contract.networks {
            Some(network_ids) => network_ids.clone(),
            None => all_network_ids.clone(),
        };

        for network_id in contract_network_ids.iter() {
            let mut network_config = network_map.get_mut(network_id).expect(
                format!("Contract network {} not defined in networks", network_id).as_str(),
            );
            network_config.contracts.push(contract.clone());
        }

        //check for networks and if nothing push to each network
    }
    let chain_configs: Vec<ChainConfig> = network_map.into_values().collect();
    chain_configs
}

#[cfg(test)]
mod tests {
    use super::ChainConfig;

    #[test]
    fn convert_to_chain_configs_case_1() {
        let network1 = super::Network {
            id: 1,
            rpc_url: String::from("https://eth.com"),
            start_block: 0,
        };

        let network2 = super::Network {
            id: 2,
            rpc_url: String::from("https://network2.com"),
            start_block: 123,
        };

        let networks = vec![network1.clone(), network2.clone()];

        let event1 = super::Event {
            name: String::from("NewGravatar"),
            read_entities: None,
        };

        let event2 = super::Event {
            name: String::from("UpdateGravatar"),
            read_entities: None,
        };

        let contract1 = super::ConfigContract {
            networks: None,
            name: String::from("Contract1"),
            abi: String::from("abi/Contract1.json"),
            address: String::from("0x2E645469f354BB4F5c8a05B3b30A929361cf77eC"),
            events: vec![event1, event2],
        };

        let contracts = vec![contract1.clone()];

        let config = super::Config {
            version: String::from("1.0.0"),
            description: String::from("Test Scenario 1"),
            repository: String::from("github.indexer.com"),
            networks,
            contracts: contracts.clone(),
            handler: String::from("../src/Contract1Handler.bs.js"),
        };

        let chain_configs = super::convert_config_to_chain_configs(&config);

        let chain_config_1 = ChainConfig {
            network_config: network1,
            contracts: contracts.clone(),
        };
        let chain_config_2 = ChainConfig {
            network_config: network2,
            contracts: contracts,
        };

        assert_eq!(chain_configs[0], chain_config_1);
        assert_eq!(chain_configs[1], chain_config_2);
    }

    #[test]
    fn convert_to_chain_configs_case_2() {
        let network1 = super::Network {
            id: 1,
            rpc_url: String::from("https://eth.com"),
            start_block: 0,
        };

        let network2 = super::Network {
            id: 2,
            rpc_url: String::from("https://network2.com"),
            start_block: 123,
        };

        let networks = vec![network1.clone(), network2.clone()];

        let event1 = super::Event {
            name: String::from("NewGravatar"),
            read_entities: None,
        };

        let event2 = super::Event {
            name: String::from("UpdateGravatar"),
            read_entities: None,
        };

        let contract1 = super::ConfigContract {
            networks: Some(vec![1]),
            name: String::from("Contract1"),
            abi: String::from("abi/Contract1.json"),
            address: String::from("0x2E645469f354BB4F5c8a05B3b30A929361cf77eC"),
            events: vec![event1, event2],
        };

        let contracts = vec![contract1.clone()];

        let config = super::Config {
            version: String::from("1.0.0"),
            description: String::from("Test Scenario 1"),
            repository: String::from("github.indexer.com"),
            networks,
            contracts: contracts.clone(),
            handler: String::from("../src/Contract1Handler.bs.js"),
        };

        let chain_configs = super::convert_config_to_chain_configs(&config);

        let chain_config_1 = ChainConfig {
            network_config: network1,
            contracts: contracts.clone(),
        };
        let chain_config_2 = ChainConfig {
            network_config: network2,
            contracts: vec![],
        };

        assert_eq!(chain_configs[0], chain_config_1);
        assert_eq!(chain_configs[1], chain_config_2);
    }
}

// network -> contracts
//
//loop through every contract and get networkIds,
//hashmap of networkIds push contracts that match onto relevant networkIds
