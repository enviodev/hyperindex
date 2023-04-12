use crate::{
    capitalization::Capitalize,
    config_parsing::{Config, ConfigContract},
    Contract, Error, ParamType, RecordType,
};

use ethereum_abi::{Abi, Event};

fn parse_abi(abi: &str) -> Result<Abi, Box<dyn Error>> {
    let abi: Abi = serde_json::from_str(abi)?;
    Ok(abi)
}

fn get_abi_from_file_path(file_path: &str) -> Result<Abi, Box<dyn Error>> {
    let abi_file = std::fs::read_to_string(file_path)?;
    parse_abi(&abi_file)
}

fn get_record_type_from_event(event: &Event) -> RecordType {
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
    event_type
}

fn get_contract_type_from_config_contract(
    config_contract: &ConfigContract,
    contract_abi: Abi,
) -> Contract {
    let mut event_types: Vec<RecordType> = Vec::new();

    let events: Vec<ethereum_abi::Event> = contract_abi.events;
    for event in config_contract.events.iter() {
        println!("{}", event.name);
        let event = events
            .iter()
            .find(|&abi_event| abi_event.name == event.name);

        match event {
            Some(event) => {
                let event_type = get_record_type_from_event(event);
                event_types.push(event_type);
            }
            None => (),
        };
    }
    let contract = Contract {
        name: config_contract.name.to_capitalized_options(),
        events: event_types,
    };
    contract
}
pub fn get_contract_types_from_config(
    project_root_path: &str,
    config: Config,
) -> Result<Vec<Contract>, Box<dyn Error>> {
    let mut contracts: Vec<Contract> = Vec::new();
    for config_contract in config.contracts.iter() {
        let mut event_types: Vec<RecordType> = Vec::new();
        let abi_path = format!("{}/{}", project_root_path, config_contract.abi_file_path);
        let contract_abi = get_abi_from_file_path(&abi_path)?;
        let contract = get_contract_type_from_config_contract(config_contract, contract_abi);
        contracts.push(contract);
    }
    Ok(contracts)
}
