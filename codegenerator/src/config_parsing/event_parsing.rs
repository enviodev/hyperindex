use pathdiff::diff_paths;
use std::{any::type_name, path::PathBuf};

use crate::{
    capitalization::Capitalize,
    config_parsing::{ConfigContract, Event as ConfigEvent},
    linked_hashtable::RescripRecordHirarchyLinkedHashMap,
    Contract, Error, EventTemplate, HandlerPaths, ParamType, RecordType, RequiredEntityTemplate,
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

fn abi_type_to_rescript_string(
    param: &ethereum_abi::Param,
    // abi_type: &ethereum_abi::Type,
    rescript_subrecord_dependencies: &RescripRecordHirarchyLinkedHashMap,
) -> String {
    match param.type_ {
        ethereum_abi::Type::Uint(_size) => String::from("Ethers.BigInt.t"),
        ethereum_abi::Type::Int(_size) => String::from("Ethers.BigInt.t"),
        ethereum_abi::Type::Bool => String::from("bool"),
        ethereum_abi::Type::Address => String::from("Ethers.ethAddress"),
        ethereum_abi::Type::Bytes => String::from("string"),
        ethereum_abi::Type::String => String::from("string"),
        ethereum_abi::Type::FixedBytes(_) => String::from("type_not_handled"),
        ethereum_abi::Type::Array(abi_type) => {
            format!(
                "array<{}>",
                abi_type_to_rescript_string(param, rescript_subrecord_dependencies)
            )
        }
        ethereum_abi::Type::FixedArray(abi_type, _) => {
            format!(
                "array<{}>",
                abi_type_to_rescript_string(param, rescript_subrecord_dependencies)
            )
        }
        ethereum_abi::Type::Tuple(abi_types) => {
            let record_name = match param.name.as_str() {
                "" => String::from("unnamed"),
                name => name.to_string(),
            };

            let rescript_params: Vec<ParamType> = abi_types
                .iter()
                .enumerate()
                .map(|(i, (field_name, abi_type))| {
                    let key = match field_name.as_str() {
                        "" => format!("@as({}) {})", i.to_string(), i.to_string()),
                        name => name.to_string(),
                    };

                    let ethereum_param = ethereum_abi::Param {
                        name: key,
                        type_: abi_type.clone(),
                        indexed: None,
                    };
                    let type_ = abi_type_to_rescript_string(
                        &ethereum_param,
                        rescript_subrecord_dependencies,
                    );

                    ParamType { key, type_ }
                })
                .collect();

            let record = RecordType {
                name: record_name.to_capitalized_options(),
                params: rescript_params,
            };
            let type_name = rescript_subrecord_dependencies.insert(record_name, record);

            type_name
        }
    }
}

fn get_event_template_from_event(
    config_event: &ConfigEvent,
    abi_event: &EthereumAbiEvent,
    rescript_subrecord_dependencies: &RescripRecordHirarchyLinkedHashMap,
) -> EventTemplate {
    let name = abi_event.name.to_owned().to_capitalized_options();
    let params = abi_event
        .inputs
        .iter()
        .map(|input| ParamType {
            key: input.name.to_owned(),
            type_: abi_type_to_rescript_string(&input.type_, rescript_subrecord_dependencies),
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

fn get_contract_handler_paths(
    config_contract: &ConfigContract,
    project_root_path: &PathBuf,
    code_gen_path: &PathBuf,
) -> Result<HandlerPaths, Box<dyn Error>> {
    let handler_path_joined = project_root_path.join(
        config_contract
            .handler
            .clone()
            .unwrap_or(String::from("./src/handlers.js")), // TODO make a better default (based on contract name or something.)
    );

    let handler_path_absolute = handler_path_joined.canonicalize()?;

    let mut get_contract_type_from_config_contract_canonicalized = code_gen_path.canonicalize()?;

    get_contract_type_from_config_contract_canonicalized.push("src");

    let handler_path_diff = diff_paths(
        handler_path_absolute.clone(),
        &get_contract_type_from_config_contract_canonicalized,
    )
    .ok_or("diff paths failed")?;

    let handler_path_relative = handler_path_diff
        .to_str()
        .unwrap_or("../../src/handlers.js");

    let handler_paths = HandlerPaths {
        absolute: handler_path_absolute
            .to_str()
            .ok_or("<Error generating path. Please file an issue at https://github.com/Float-Capital/indexer/issues/new>")?
            .to_owned(),
        relative_to_generated_src: handler_path_relative.to_owned(),
    };

    Ok(handler_paths)
}

fn get_contract_type_from_config_contract(
    config_contract: &ConfigContract,
    contract_abi: Abi,
    project_root_path: &PathBuf,
    code_gen_path: &PathBuf,
    rescript_subrecord_dependencies: &RescripRecordHirarchyLinkedHashMap,
) -> Result<Contract, Box<dyn Error>> {
    let mut event_types: Vec<EventTemplate> = Vec::new();

    let abi_events: Vec<ethereum_abi::Event> = contract_abi.events;
    for config_event in config_contract.events.iter() {
        let abi_event = abi_events
            .iter()
            .find(|&abi_event| abi_event.name == config_event.name);

        match abi_event {
            Some(abi_event) => {
                let event_type = get_event_template_from_event(
                    config_event,
                    abi_event,
                    rescript_subrecord_dependencies,
                );
                event_types.push(event_type);
            }
            None => (),
        };
    }

    let handler = get_contract_handler_paths(config_contract, project_root_path, code_gen_path)?;

    let contract = Contract {
        name: config_contract.name.to_capitalized_options(),
        events: event_types,
        handler,
    };

    Ok(contract)
}

pub fn get_contract_types_from_config(
    config_path: &PathBuf,
    project_root_path: &PathBuf,
    code_gen_path: &PathBuf,
    rescript_subrecord_dependencies: &RescripRecordHirarchyLinkedHashMap,
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
                rescript_subrecord_dependencies,
            )?;
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
        linked_hashtable::RescripRecordHirarchyLinkedHashMap,
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
        let rescript_subrecord_dependencies = RescripRecordHirarchyLinkedHashMap::new();
        let parsed_event_template = get_event_template_from_event(
            &config_event,
            &abi_event,
            &rescript_subrecord_dependencies,
        );

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

        let rescript_subrecord_dependencies = RescripRecordHirarchyLinkedHashMap::new();
        let parsed_event_template = get_event_template_from_event(
            &config_event,
            &abi_event,
            &rescript_subrecord_dependencies,
        );

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

        let rescript_subrecord_dependencies = RescripRecordHirarchyLinkedHashMap::new();
        let parsed_rescript_string =
            abi_type_to_rescript_string(&array_string_type, &rescript_subrecord_dependencies);

        assert_eq!(parsed_rescript_string, String::from("array<string>"))
    }
    #[test]
    fn test_record_type_fixed_array() {
        let array_string_type = Type::FixedArray(Box::new(Type::String), 1);
        let rescript_subrecord_dependencies = RescripRecordHirarchyLinkedHashMap::new();
        let parsed_rescript_string =
            abi_type_to_rescript_string(&array_string_type, &rescript_subrecord_dependencies);

        assert_eq!(parsed_rescript_string, String::from("array<string>"))
    }

    #[test]
    fn test_record_type_tuple() {
        let tuple_type = Type::Tuple(vec![
            (String::from("unused_name"), Type::String),
            (String::from("unused_name2"), Type::Uint(256)),
        ]);
        let rescript_subrecord_dependencies = RescripRecordHirarchyLinkedHashMap::new();
        let parsed_rescript_string =
            abi_type_to_rescript_string(&tuple_type, &rescript_subrecord_dependencies);

        assert_eq!(
            parsed_rescript_string,
            String::from("(string, Ethers.BigInt.t)")
        )
    }
}
