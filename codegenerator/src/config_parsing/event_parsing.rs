use pathdiff::diff_paths;
use std::path::PathBuf;

use crate::{
    capitalization::Capitalize,
    config_parsing::{ConfigContract, Event as ConfigEvent},
    Contract, Error, EventTemplate, HandlerPaths, ParamType, RequiredEntityTemplate,
};

use ethereum_abi::{Abi, Event as EthereumAbiEvent};

use super::deserialize_config_from_yaml;

pub fn parse_abi(abi: &str) -> Result<Abi, Box<dyn Error>> {
    let abi: Abi = serde_json::from_str(abi)?;
    Ok(abi)
}

pub fn get_abi_from_file_path(file_path: &PathBuf) -> Result<Abi, Box<dyn Error>> {
    let abi_file = std::fs::read_to_string(file_path)?;
    parse_abi(&abi_file)
}

fn abi_type_to_rescript_string(abi_type: &ethereum_abi::Type) -> String {
    match abi_type {
        ethereum_abi::Type::Uint(_size) => String::from("Ethers.BigInt.t"),
        ethereum_abi::Type::Int(_size) => String::from("Ethers.BigInt.t"),
        ethereum_abi::Type::Bool => String::from("bool"),
        ethereum_abi::Type::Address => String::from("Ethers.ethAddress"),
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
                .map(|(_field_name, abi_type)| abi_type_to_rescript_string(abi_type))
                .collect();

            format!("({})", rescript_abi_types.join(", "))
            //when this comes in we actually want to make a new record, simply define the name of the record in
            //here and then push the append the record to the head of an array of records that need to be
            //defined before this.
            //We need to ensure that there is no duplication of these "sub record" types
            //
            //need a function that takes an event type makes the record but takes a  second argument of an
            //array of sub records that can be appended.
            //these sub records should be tested for their uniqueness in both naming and shape
            //all sub records of all records need to be tested for uniqueness and naming
            //
            //rescript type should be an enum
            //
            //an initial implementation could avoid aliases but should still check for double names and either
            //remove the second if they have the same record type or add an incrementor to the the name of the
            //second (the name should then be changed where it gets referenced)
        }
    }
}

fn get_event_template_from_event(
    config_event: &ConfigEvent,
    abi_event: &EthereumAbiEvent,
) -> EventTemplate {
    let name = abi_event.name.to_owned().to_capitalized_options();
    let params = abi_event
        .inputs
        .iter()
        .map(|input| ParamType {
            key: input.name.to_owned(),
            type_: abi_type_to_rescript_string(&input.type_),
        })
        .collect();

    let required_entities = match &config_event.required_entities {
        Some(required_entities_config) => required_entities_config
            .iter()
            .map(|required_entity| RequiredEntityTemplate {
                name: required_entity.name.to_capitalized_options(),
                labels: required_entity.labels.clone(),
            })
            .collect(),
        None => Vec::new(),
    };

    let event_type = EventTemplate {
        name,
        params,
        required_entities,
    };

    event_type
}

fn get_contract_type_from_config_contract(
    config_contract: &ConfigContract,
    contract_abi: Abi,
    project_root_path: &PathBuf,
    get_contract_type_from_config_contract: &PathBuf,
) -> Contract {
    let mut event_types: Vec<EventTemplate> = Vec::new();

    let abi_events: Vec<ethereum_abi::Event> = contract_abi.events;
    for config_event in config_contract.events.iter() {
        let abi_event = abi_events
            .iter()
            .find(|&abi_event| abi_event.name == config_event.name);

        match abi_event {
            Some(abi_event) => {
                let event_type = get_event_template_from_event(config_event, abi_event);
                event_types.push(event_type);
            }
            None => (),
        };
    }
    let handler_path_joined = project_root_path.join(
        config_contract
            .handler
            .clone()
            .unwrap_or(String::from("./src/handlers.js")), // TODO make a better default (based on contract name or something.)
    );
    let handler_path_absolute = handler_path_joined.canonicalize().expect(&format!(
        "event handler file {} not found",
        handler_path_joined.display()
    ));

    let mut get_contract_type_from_config_contract_canonicalized =
        get_contract_type_from_config_contract
            .canonicalize()
            .unwrap();

    get_contract_type_from_config_contract_canonicalized.push("src");

    let handler_path_diff = diff_paths(
        handler_path_absolute.clone(),
        &get_contract_type_from_config_contract_canonicalized,
    )
    .unwrap();

    let handler_path_relative = handler_path_diff
        .to_str()
        .unwrap_or("../../src/handlers.js");

    let handler_paths = HandlerPaths {
        absolute: handler_path_absolute
            .to_str()
            .unwrap_or("<Error generating path. Please file an issue at https://github.com/Float-Capital/indexer/issues/new>")
            .to_owned(),
        relative_to_generated_src: handler_path_relative.to_owned(),
    };

    let contract = Contract {
        name: config_contract.name.to_capitalized_options(),
        events: event_types,
        handler: handler_paths,
    };

    contract
}

pub fn get_contract_types_from_config(
    config_path: &PathBuf,
    project_root_path: &PathBuf,
    code_gen_path: &PathBuf,
) -> Result<Vec<Contract>, Box<dyn Error>> {
    let config = deserialize_config_from_yaml(config_path)?;
    let mut contracts: Vec<Contract> = Vec::new();
    for network in config.networks.iter() {
        for config_contract in network.contracts.iter() {
            let config_parent_path = config_path
                .parent()
                .expect("config path should have a parent directory");
            let parsed_abi: Abi =
                get_abi_from_file_path(&config_parent_path.join(&config_contract.abi_file_path))?;

            let contract = get_contract_type_from_config_contract(
                config_contract,
                parsed_abi,
                project_root_path,
                code_gen_path,
            );
            contracts.push(contract);
        }
    }
    Ok(contracts)
}

#[cfg(test)]
mod tests {

    use crate::{
        capitalization::Capitalize,
        config_parsing::{self, RequiredEntity},
        EventTemplate, ParamType, RequiredEntityTemplate,
    };
    use ethereum_abi::{Event as AbiEvent, Param, Type};

    use super::{abi_type_to_rescript_string, get_event_template_from_event};
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

        let abi_event = AbiEvent {
            name: event_name.clone(),
            anonymous: false,
            inputs,
        };
        let config_event = config_parsing::Event {
            name: event_name.clone(),
            required_entities: None,
        };

        let parsed_event_template = get_event_template_from_event(&config_event, &abi_event);

        let expected_event_template = EventTemplate {
            name: event_name.to_capitalized_options(),
            params: vec![
                ParamType {
                    key: input1_name,
                    type_: String::from("Ethers.BigInt.t"),
                },
                ParamType {
                    key: input2_name,
                    type_: String::from("Ethers.ethAddress"),
                },
            ],
            required_entities: vec![],
        };
        assert_eq!(parsed_event_template, expected_event_template)
    }

    #[test]
    fn abi_event_to_record_2() {
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

        let abi_event = AbiEvent {
            name: event_name.clone(),
            anonymous: false,
            inputs,
        };
        let config_event = config_parsing::Event {
            name: event_name.clone(),
            required_entities: Some(vec![RequiredEntity {
                name: String::from("Gravatar"),
                labels: vec![String::from("gravatarWithChanges")],
            }]),
        };

        let parsed_event_template = get_event_template_from_event(&config_event, &abi_event);

        let expected_event_template = EventTemplate {
            name: event_name.to_capitalized_options(),
            params: vec![
                ParamType {
                    key: input1_name,
                    type_: String::from("Ethers.BigInt.t"),
                },
                ParamType {
                    key: input2_name,
                    type_: String::from("Ethers.ethAddress"),
                },
            ],
            required_entities: vec![RequiredEntityTemplate {
                name: String::from("Gravatar").to_capitalized_options(),
                labels: vec![String::from("gravatarWithChanges")],
            }],
        };
        assert_eq!(parsed_event_template, expected_event_template)
    }

    #[test]
    fn test_record_type_array() {
        let array_string_type = Type::Array(Box::new(Type::String));
        let parsed_rescript_string = abi_type_to_rescript_string(&array_string_type);

        assert_eq!(parsed_rescript_string, String::from("array<string>"))
    }
    #[test]
    fn test_record_type_fixed_array() {
        let array_string_type = Type::FixedArray(Box::new(Type::String), 1);
        let parsed_rescript_string = abi_type_to_rescript_string(&array_string_type);

        assert_eq!(parsed_rescript_string, String::from("array<string>"))
    }

    #[test]
    fn test_record_type_tuple() {
        let tuple_type = Type::Tuple(vec![
            (String::from("unused_name"), Type::String),
            (String::from("unused_name2"), Type::Uint(256)),
        ]);
        let parsed_rescript_string = abi_type_to_rescript_string(&tuple_type);

        assert_eq!(
            parsed_rescript_string,
            String::from("(string, Ethers.BigInt.t)")
        )
    }
}
