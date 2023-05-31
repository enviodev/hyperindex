use crate::{
    capitalization::Capitalize,
    config_parsing::{ConfigContract, Event as ConfigEvent},
    linked_hashmap::RescriptRecordHierarchyLinkedHashMap,
    project_paths::{handler_paths::ContractUniqueId, ParsedPaths},
    Contract, Error, EventParamType, EventRecordType, EventTemplate, RequiredEntityTemplate,
};

use std::collections::HashMap;

use crate::capitalization::CapitalizedOptions;

use std::path::PathBuf;

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

struct EthereumEventParam<'a> {
    name: &'a str,
    abi_type: &'a ethereum_abi::Type,
}

impl<'a> EthereumEventParam<'a> {
    fn from_ethereum_abi_param(abi_type: &'a ethereum_abi::Param) -> EthereumEventParam<'a> {
        EthereumEventParam {
            name: &abi_type.name,
            abi_type: &abi_type.type_,
        }
    }
}

fn abi_type_to_rescript_string(
    param: &EthereumEventParam,
    rescript_subrecord_dependencies: &mut RescriptRecordHierarchyLinkedHashMap<EventRecordType>,
) -> String {
    match &param.abi_type {
        ethereum_abi::Type::Uint(_size) => String::from("Ethers.BigInt.t"),
        ethereum_abi::Type::Int(_size) => String::from("Ethers.BigInt.t"),
        ethereum_abi::Type::Bool => String::from("bool"),
        ethereum_abi::Type::Address => String::from("Ethers.ethAddress"),
        ethereum_abi::Type::Bytes => String::from("string"),
        ethereum_abi::Type::String => String::from("string"),
        ethereum_abi::Type::FixedBytes(_) => String::from("string"),
        ethereum_abi::Type::Array(abi_type) => {
            let sub_param = EthereumEventParam {
                abi_type: &abi_type,
                name: param.name,
            };
            format!(
                "array<{}>",
                abi_type_to_rescript_string(&sub_param, rescript_subrecord_dependencies)
            )
        }
        ethereum_abi::Type::FixedArray(abi_type, _) => {
            let sub_param = EthereumEventParam {
                abi_type: &abi_type,
                name: param.name,
            };

            format!(
                "array<{}>",
                abi_type_to_rescript_string(&sub_param, rescript_subrecord_dependencies)
            )
        }
        ethereum_abi::Type::Tuple(abi_types) => {
            let record_name = match param.name {
                "" => "unnamed".to_string(),
                name => name.to_string(),
            };

            let rescript_params: Vec<EventParamType> = abi_types
                .iter()
                .enumerate()
                .map(|(i, (field_name, abi_type))| {
                    let key = match field_name.as_str() {
                        "" => format!("@as({}) _{})", i, i),
                        name => name.to_string(),
                    };

                    let ethereum_param = EthereumEventParam {
                        name: &key,
                        abi_type: &abi_type,
                    };
                    let type_rescript = abi_type_to_rescript_string(
                        &ethereum_param,
                        rescript_subrecord_dependencies,
                    );

                    EventParamType { key, type_rescript }
                })
                .collect();

            let record = EventRecordType {
                name: record_name.to_capitalized_options(),
                params: rescript_params,
            };
            let type_name = rescript_subrecord_dependencies.insert(record_name, record);

            type_name
        }
    }
}

fn get_event_template_from_ethereum_abi_event(
    config_event: &ConfigEvent,
    abi_event: &EthereumAbiEvent,
    rescript_subrecord_dependencies: &mut RescriptRecordHierarchyLinkedHashMap<EventRecordType>,
    entity_fields_of_required_entity_map: &HashMap<String, Vec<CapitalizedOptions>>,
) -> EventTemplate {
    let name = abi_event.name.to_owned().to_capitalized_options();
    let params = abi_event
        .inputs
        .iter()
        .map(|input| EventParamType {
            key: input.name.to_owned(),
            type_rescript: abi_type_to_rescript_string(
                &EthereumEventParam::from_ethereum_abi_param(input),
                rescript_subrecord_dependencies,
            ),
        })
        .collect();

    let required_entities = match &config_event.required_entities {
        Some(required_entities_config) => required_entities_config
            .iter()
            .map(|required_entity| RequiredEntityTemplate {
                name: required_entity.name.to_capitalized_options(),
                labels: required_entity.labels.clone(),
                entity_fields_of_required_entity: entity_fields_of_required_entity_map
                    .get(&required_entity.name)
                    .cloned()
                    .unwrap_or_else(Vec::new),
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
    parsed_paths: &ParsedPaths,
    contract_unique_id: ContractUniqueId,
    rescript_subrecord_dependencies: &mut RescriptRecordHierarchyLinkedHashMap<EventRecordType>,
    entity_fields_of_required_entity_map: &HashMap<String, Vec<CapitalizedOptions>>,
) -> Result<Contract, Box<dyn Error>> {
    let mut event_types: Vec<EventTemplate> = Vec::new();

    let contract_abi = parsed_paths.get_contract_abi(&contract_unique_id)?;

    let abi_events: Vec<ethereum_abi::Event> = contract_abi.events;
    for config_event in config_contract.events.iter() {
        let abi_event = abi_events
            .iter()
            .find(|&abi_event| abi_event.name == config_event.name);

        match abi_event {
            Some(abi_event) => {
                let event_type = get_event_template_from_ethereum_abi_event(
                    config_event,
                    abi_event,
                    rescript_subrecord_dependencies,
                    entity_fields_of_required_entity_map,
                    // &(entity_fields_of_required_entity_map
                    //     .get(&config_event.name)
                    //     .map(|vec| *vec)),
                );
                event_types.push(event_type);
            }
            None => (),
        };
    }

    let handler_template = parsed_paths.get_contract_handler_paths_template(&contract_unique_id)?;

    let contract = Contract {
        name: config_contract.name.to_capitalized_options(),
        events: event_types,
        handler: handler_template,
    };

    Ok(contract)
}

pub fn get_contract_types_from_config(
    parsed_paths: &ParsedPaths,
    rescript_subrecord_dependencies: &mut RescriptRecordHierarchyLinkedHashMap<EventRecordType>,
    entity_fields_of_required_entity_map: &HashMap<String, Vec<CapitalizedOptions>>,
) -> Result<Vec<Contract>, Box<dyn Error>> {
    let config = deserialize_config_from_yaml(&parsed_paths.project_paths.config)?;
    let mut contracts: Vec<Contract> = Vec::new();
    for network in config.networks.iter() {
        for config_contract in network.contracts.iter() {
            let contract_unique_id = ContractUniqueId {
                network_id: network.id,
                name: config_contract.name.clone(),
            };

            let contract = get_contract_type_from_config_contract(
                config_contract,
                parsed_paths,
                contract_unique_id,
                rescript_subrecord_dependencies,
                entity_fields_of_required_entity_map,
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
        linked_hashmap::RescriptRecordHierarchyLinkedHashMap,
        EventParamType, EventRecordType, EventTemplate, RequiredEntityTemplate,
    };
    use ethereum_abi::{Event as AbiEvent, Param, Type};

    use super::{abi_type_to_rescript_string, get_event_template_from_ethereum_abi_event};
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
        let mut rescript_subrecord_dependencies = RescriptRecordHierarchyLinkedHashMap::new();
        let parsed_event_template = get_event_template_from_ethereum_abi_event(
            &config_event,
            &abi_event,
            &mut rescript_subrecord_dependencies,
            &HashMap::new(),
        );

        let expected_event_template = EventTemplate {
            name: event_name.to_capitalized_options(),
            params: vec![
                EventParamType {
                    key: input1_name,
                    type_rescript: String::from("Ethers.BigInt.t"),
                },
                EventParamType {
                    key: input2_name,
                    type_rescript: String::from("Ethers.ethAddress"),
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

        let mut rescript_subrecord_dependencies = RescriptRecordHierarchyLinkedHashMap::new();
        let parsed_event_template = get_event_template_from_ethereum_abi_event(
            &config_event,
            &abi_event,
            &mut rescript_subrecord_dependencies,
            &HashMap::new(),
        );

        let expected_event_template = EventTemplate {
            name: event_name.to_capitalized_options(),
            params: vec![
                EventParamType {
                    key: input1_name,
                    type_rescript: String::from("Ethers.BigInt.t"),
                },
                EventParamType {
                    key: input2_name,
                    type_rescript: String::from("Ethers.ethAddress"),
                },
            ],
            required_entities: vec![RequiredEntityTemplate {
                name: String::from("Gravatar").to_capitalized_options(),
                labels: vec![String::from("gravatarWithChanges")],
                entity_fields_of_required_entity: Vec::new(),
            }],
        };
        assert_eq!(parsed_event_template, expected_event_template)
    }

    #[test]
    fn test_record_type_array() {
        let array_string_type = Type::Array(Box::new(Type::String));
        let param = super::EthereumEventParam {
            abi_type: &array_string_type,
            name: "myArray",
        };

        let mut rescript_subrecord_dependencies = RescriptRecordHierarchyLinkedHashMap::new();
        let parsed_rescript_string =
            abi_type_to_rescript_string(&param, &mut rescript_subrecord_dependencies);

        assert_eq!(parsed_rescript_string, String::from("array<string>"))
    }
    #[test]
    fn test_record_type_fixed_array() {
        let array_fixed_arr_type = Type::FixedArray(Box::new(Type::String), 1);
        let param = super::EthereumEventParam {
            abi_type: &array_fixed_arr_type,
            name: "myArrayFixed",
        };
        let mut rescript_subrecord_dependencies = RescriptRecordHierarchyLinkedHashMap::new();
        let parsed_rescript_string =
            abi_type_to_rescript_string(&param, &mut rescript_subrecord_dependencies);

        assert_eq!(parsed_rescript_string, String::from("array<string>"))
    }

    #[test]
    fn test_record_type_tuple() {
        let tuple_type = Type::Tuple(vec![
            (String::from("myString"), Type::String),
            (String::from("myUint256"), Type::Uint(256)),
        ]);
        let param = super::EthereumEventParam {
            abi_type: &tuple_type,
            name: "myStruct",
        };
        let mut rescript_subrecord_dependencies = RescriptRecordHierarchyLinkedHashMap::new();
        let parsed_rescript_string =
            abi_type_to_rescript_string(&param, &mut rescript_subrecord_dependencies);

        let parsed_sub_records = rescript_subrecord_dependencies
            .iter()
            .collect::<Vec<EventRecordType>>();
        let expected_sub_records = vec![EventRecordType {
            name: String::from("myStruct").to_capitalized_options(),
            params: vec![
                EventParamType {
                    key: "myString".to_string(),
                    type_rescript: "string".to_string(),
                },
                EventParamType {
                    key: "myUint256".to_string(),
                    type_rescript: "Ethers.BigInt.t".to_string(),
                },
            ],
        }];
        assert_eq!(parsed_rescript_string, String::from("myStruct"));
        assert_eq!(parsed_sub_records, expected_sub_records);
    }
}
