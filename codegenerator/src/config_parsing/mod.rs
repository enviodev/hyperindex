use std::collections::HashMap;
use std::error::Error;

pub mod entity_parsing;
pub mod event_parsing;

use serde::{Deserialize, Serialize};

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
struct ContractNetwork {
    id: NetworkId,
    addresses: Vec<String>,
}

#[derive(Debug, Serialize, Deserialize, Clone, PartialEq)]
pub struct ConfigContract {
    name: String,
    abi_file_path: String,
    networks: Vec<ContractNetwork>,
    events: Vec<Event>,
}

#[derive(Debug, Serialize, Deserialize, Clone, PartialEq)]
struct SingleContract {
    name: String,
    abi: String,
    address: String,
    events: Vec<Event>,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct Config {
    version: String,
    description: String,
    repository: String,
    networks: Vec<Network>,
    handler: String,
    contracts: Vec<ConfigContract>,
}

#[derive(Debug, PartialEq, Clone)]
struct ChainConfig {
    network_config: Network,
    contracts: Vec<SingleContract>,
}

pub fn get_config_from_yaml(project_root_path: &str) -> Result<Config, Box<dyn Error>> {
    let config_dir = format!("{}/{}", project_root_path, "config.yaml");

    let config = std::fs::read_to_string(&config_dir)?;

    let deserialized_yaml: Config = serde_yaml::from_str(&config)?;
    Ok(deserialized_yaml)
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
        for contract_network in contract.networks.iter() {
            let network_config = network_map.get_mut(&contract_network.id).expect(
                format!(
                    "Contract network {} not defined in networks",
                    contract_network.id
                )
                .as_str(),
            );
            for contract_address in contract_network.addresses.iter() {
                let single_contract = SingleContract {
                    name: contract.name.clone(),
                    abi: String::from("../../abis/Dummy.json"),
                    address: contract_address.clone(),
                    events: contract.events.clone(),
                };
                network_config.contracts.push(single_contract);
            }
        }

        //check for networks and if nothing push to each network
    }

    let mut chain_configs: Vec<ChainConfig> = Vec::new();
    for network in config.networks.iter() {
        let chain_config = network_map.get(&network.id).expect(
            format!(
                "Network id {} should have been set in first iteration",
                network.id
            )
            .as_str(),
        );

        chain_configs.push(chain_config.clone());
    }

    chain_configs
}

#[cfg(test)]
mod tests {
    use crate::event_parsing::ContractNetwork;

    use super::ChainConfig;

    #[test]
    fn convert_to_chain_configs_case_1() {
        let address1 = String::from("0x2E645469f354BB4F5c8a05B3b30A929361cf77eC");
        let address2 = String::from("0x1E645469f354BB4F5c8a05B3b30A929361cf77eC");
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

        let contract_network_config1 = ContractNetwork {
            id: 1,
            addresses: vec![address1.clone()],
        };

        let contract_network_config2 = super::ContractNetwork {
            id: 2,
            addresses: vec![address2.clone()],
        };

        let contract_networks_config = vec![contract_network_config1, contract_network_config2];
        let contract1 = super::ConfigContract {
            networks: contract_networks_config,
            name: String::from("Contract1"),
            abi: String::from("abi/Contract1.json"),
            events: vec![event1.clone(), event2.clone()],
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

        let single_contract1 = super::SingleContract {
            name: String::from("Contract1"),
            abi: String::from("abi/Contract1.json"),
            address: address1.clone(),
            events: vec![event1.clone(), event2.clone()],
        };
        let single_contract2 = super::SingleContract {
            name: String::from("Contract1"),
            abi: String::from("abi/Contract1.json"),
            address: address2.clone(),
            events: vec![event1, event2],
        };

        let chain_config_1 = ChainConfig {
            network_config: network1,
            contracts: vec![single_contract1],
        };
        let chain_config_2 = ChainConfig {
            network_config: network2,
            contracts: vec![single_contract2],
        };

        assert_eq!(chain_configs[0], chain_config_1);
        assert_eq!(chain_configs[1], chain_config_2);
    }

    #[test]
    fn convert_to_chain_configs_case_2() {
        let address1 = String::from("0x2E645469f354BB4F5c8a05B3b30A929361cf77eC");
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

        let contract_network_config1 = ContractNetwork {
            id: 1,
            addresses: vec![address1.clone()],
        };

        let contract_networks_config = vec![contract_network_config1];
        let contract1 = super::ConfigContract {
            networks: contract_networks_config,
            name: String::from("Contract1"),
            abi: String::from("abi/Contract1.json"),
            events: vec![event1.clone(), event2.clone()],
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

        let single_contract1 = super::SingleContract {
            name: String::from("Contract1"),
            abi: String::from("abi/Contract1.json"),
            address: address1.clone(),
            events: vec![event1, event2],
        };

        let chain_config_1 = ChainConfig {
            network_config: network1,
            contracts: vec![single_contract1],
        };
        let chain_config_2 = ChainConfig {
            network_config: network2,
            contracts: vec![],
        };

        assert_eq!(chain_configs[0], chain_config_1);
        assert_eq!(chain_configs[1], chain_config_2);
    }
}
