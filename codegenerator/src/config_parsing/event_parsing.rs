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

fn abi_type_to_rescript_string(abi_type: &ethereum_abi::Type) -> String {
    match abi_type {
        ethereum_abi::Type::Uint(_size) => String::from("Ethers.BigInt.t"),
        ethereum_abi::Type::Int(_size) => String::from("Ethers.BigInt.t"),
        ethereum_abi::Type::Bool => String::from("bool"),
        ethereum_abi::Type::Address => String::from("Ethers.address"),
        ethereum_abi::Type::Bytes => String::from("string"),
        ethereum_abi::Type::String => String::from("string"),
        ethereum_abi::Type::FixedBytes(_) => String::from("type_not_handled"),
        ethereum_abi::Type::Array(abi_type) => {
            format!("array<{}>", abi_type_to_rescript_string(abi_type))
        }
        ethereum_abi::Type::FixedArray(abi_type, _) => {
            format!("array<{}>", abi_type_to_rescript_string(abi_type))
        }
        ethereum_abi::Type::Tuple(abi_types) => {
            //TODO:
            //Not sure if we should inline tuples like this. Maybe we should rather make
            //a record type above and reference it here.
            //In which case this function should return an enum of literal type and reference type.
            //Reference type means it should reference a type anoted above
            let rescript_abi_types: Vec<String> = abi_types
                .iter()
                .map(|(_field_name, abi_type)| {
                    format!("array<{}>", abi_type_to_rescript_string(abi_type))
                })
                .collect();

            format!("({})", rescript_abi_types.join(", "))
        }
    }
}

fn get_record_type_from_event(event: &Event) -> RecordType {
    let event_type = RecordType {
        name: event.name.to_owned().to_capitalized_options(),
        params: event
            .inputs
            .iter()
            .map(|input| ParamType {
                key: input.name.to_owned(),
                type_: abi_type_to_rescript_string(&input.type_),
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
        let abi_path = format!("{}/{}", project_root_path, config_contract.abi_file_path);
        let contract_abi = get_abi_from_file_path(&abi_path)?;
        let contract = get_contract_type_from_config_contract(config_contract, contract_abi);
        contracts.push(contract);
    }
    Ok(contracts)
}

#[cfg(test)]
mod tests {

    use crate::{capitalization::Capitalize, ParamType, RecordType};
    use ethereum_abi::{Event, Param, Type};

    use super::get_record_type_from_event;
    #[test]
    fn abi_event_to_record_1() {
        let input1_name = String::from("id");

        let input1 = Param {
            name: input1_name.clone(),
            indexed: Some(false),
            type_: Type::Uint(256),
        };

        let input2_name = String::from("owner");
        let input2 = Param {
            name: input2_name.clone(),
            indexed: Some(false),
            type_: Type::Address,
        };

        let inputs = vec![input1, input2];
        let event_name = String::from("NewGravatar");
        let event = Event {
            name: event_name.clone(),
            anonymous: false,
            inputs,
        };

        let parsed_record = get_record_type_from_event(&event);

        let expected_record = RecordType {
            name: event_name.to_capitalized_options(),
            params: vec![
                ParamType {
                    key: input1_name,
                    type_: String::from("Ethers.BigInt.t"),
                },
                ParamType {
                    key: input2_name,
                    type_: String::from("Ethers.address"),
                },
            ],
        };
        assert_eq!(parsed_record, expected_record)
    }
    //Todo: test array and tuple types
}
