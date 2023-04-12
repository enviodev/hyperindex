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

#[derive(Debug, Serialize, Deserialize)]
struct Network {
    id: i32,
    rpc_url: String,
    start_block: i32,
}

#[derive(Debug, Serialize, Deserialize)]
struct ReadEntity {
    name: String,
    labels: Vec<String>,
}
#[derive(Debug, Serialize, Deserialize)]
struct Event {
    name: String,
    read_entities: Option<Vec<ReadEntity>>,
}
#[derive(Debug, Serialize, Deserialize)]
struct ConfigContract {
    name: String,
    abi: String,
    address: String,
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
