///A module used for flattening and dealing with tuples and nested
///tuples in event params
mod nested_params {
    use super::*;
    pub type ParamIndex = usize;

    ///Recursive Representation of param token. With reference to it's own index
    ///if it is a tuple
    enum NestedEventParam {
        Param(ethers::abi::EventParam, ParamIndex),
        TupleParam(ParamIndex, Box<NestedEventParam>),
        Tuple(Vec<NestedEventParam>),
    }

    impl NestedEventParam {
        ///Constructs NestedEventParam from an ethers abi EventParam
        fn from(event_input: ethers::abi::EventParam, param_index: usize) -> Self {
            if let ParamType::Tuple(param_types) = event_input.kind {
                //in the tuple case return a Tuple tape with an array of inner
                //event params
                Self::Tuple(
                    param_types
                        .into_iter()
                        .enumerate()
                        .map(|(i, p)| {
                            let event_input = ethers::abi::EventParam {
                                // Keep the same name as the event input name
                                name: event_input.name.clone(),
                                kind: p,
                                //Tuple fields can't be indexed
                                indexed: false,
                            };
                            //Recursively get the inner NestedEventParam type
                            Self::TupleParam(i, Box::new(Self::from(event_input, param_index)))
                        })
                        .collect(),
                )
            } else {
                Self::Param(event_input, param_index)
            }
        }
        //Turns the recursive NestedEventParam structure into a vec of FlattenedEventParam structs
        //This is the internal function that takes an array as a second param. The public function
        //calls this with an empty vec.
        fn into_flattened_inputs_inner(
            &self,
            mut accessor_indexes: Vec<ParamIndex>,
        ) -> Vec<FlattenedEventParam> {
            match &self {
                Self::Param(e, i) => {
                    let accessor_indexes = if accessor_indexes.is_empty() {
                        None
                    } else {
                        Some(accessor_indexes)
                    };

                    vec![FlattenedEventParam {
                        event_param_pos: *i,
                        event_param: e.clone(),
                        accessor_indexes,
                    }]
                }
                Self::TupleParam(i, arg_or_tuple) => {
                    accessor_indexes.push(*i);
                    arg_or_tuple.into_flattened_inputs_inner(accessor_indexes)
                }
                Self::Tuple(params) => params
                    .iter()
                    .flat_map(|param| param.into_flattened_inputs_inner(accessor_indexes.clone()))
                    .collect::<Vec<_>>(),
            }
        }

        //Public function that converts the NestedEventParam into a Vec of FlattenedEventParams
        //calls the internal function with an empty vec of accessor indexes
        pub fn into_flattened_inputs(&self) -> Vec<FlattenedEventParam> {
            self.into_flattened_inputs_inner(vec![])
        }
    }

    ///A flattened representation of an event param, meaning
    ///tuples/structs would broken into a single FlattenedEventParam for each
    ///param that it contains and include accessor indexes for where to find that param
    ///within its parent tuple/struct
    #[derive(Debug, Clone, PartialEq)]
    pub struct FlattenedEventParam {
        event_param_pos: usize,
        pub event_param: ethers::abi::EventParam,
        pub accessor_indexes: Option<Vec<ParamIndex>>,
    }

    impl FlattenedEventParam {
        ///Gets a named paramter or constructs a name using the parameter's index
        ///if the param is nameless
        fn get_param_name(&self) -> String {
            match &self.event_param.name {
                name if name.is_empty() => format!("_{}", self.event_param_pos),
                name => name.clone(),
            }
        }
        ///Gets the key of the param for the entity representing the event
        ///If this is not a tuple it will be the same as the "event_param_key"
        ///eg. MyEventEntity has a param called myTupleParam_1_2, where as the
        ///event_param_key is myTupleParam with accessor_indexes of [1, 2]
        ///In a JS template this would be myTupleParam[1][2] to get the value of the parameter
        pub fn get_entity_key(&self) -> CapitalizedOptions {
            let accessor_indexes_string = self.accessor_indexes.as_ref().map_or_else(
                //If there is no accessor_indexes this is an empty string
                || "".to_string(),
                |accessor_indexes| {
                    format!(
                        "_{}",
                        //join each index with "_"
                        //eg. _1_2 for a double nested tuple
                        accessor_indexes
                            .iter()
                            .map(|u| u.to_string())
                            .collect::<Vec<_>>()
                            .join("_")
                    )
                },
            );

            //Join the param name with the accessor_indexes_string
            //eg. myTupleParam_1_2 or myNonTupleParam if there are no accessor indexes
            let mut entity_key = format!("{}{}", self.get_param_name(), accessor_indexes_string);

            // Check if entity_key is "id" and rename to "event_id"
            if entity_key == "id" {
                entity_key = "event_id".to_string();
            }

            entity_key.to_capitalized_options()
        }

        ///Gets the event param "key" for the event type. Will be the same
        ///as the entity key if the type is not a tuple. In the case of a tuple
        ///entity key will append _0_1 for eg to represent thested param in a flat structure
        ///the event param key will not append this and will need to access that tuple at the given
        ///index
        pub fn get_event_param_key(&self) -> CapitalizedOptions {
            self.get_param_name().to_capitalized_options()
        }

        ///Used for constructing in tests
        #[cfg(test)]
        pub fn new(
            name: &str,
            kind: ParamType,
            indexed: bool,
            accessor_indexes: Vec<usize>,
            event_param_pos: usize,
        ) -> Self {
            let accessor_indexes = if accessor_indexes.is_empty() {
                None
            } else {
                Some(accessor_indexes)
            };

            FlattenedEventParam {
                event_param_pos,
                event_param: ethers::abi::EventParam {
                    name: name.to_string(),
                    kind,
                    indexed,
                },
                accessor_indexes,
            }
        }
    }

    ///Take an event, and if any param is a tuple type,
    ///it flattens it into an event with more params
    ///MyEvent(address myAddress, (uint256, bool) myTupleParam) ->
    ///MyEvent(address myAddress, uint256 myTupleParam_1, uint256 myTupleParam_2)
    ///This representation makes it easy to have single field conversions
    pub fn flatten_event_inputs(
        event_inputs: Vec<ethers::abi::EventParam>,
    ) -> Vec<FlattenedEventParam> {
        event_inputs
            .into_iter()
            .enumerate()
            .flat_map(|(i, event_input)| {
                NestedEventParam::from(event_input, i).into_flattened_inputs()
            })
            .collect()
    }
}

use super::hbs_dir_generator::HandleBarsDirGenerator;
use crate::{
    cli_args::init_config::Language,
    config_parsing::{
        entity_parsing::{Entity, Field, FieldType, Schema},
        system_config::{self, SystemConfig},
    },
    constants::reserved_keywords::RESCRIPT_RESERVED_WORDS,
    template_dirs::TemplateDirs,
    utils::text::{Capitalize, CapitalizedOptions},
};
use anyhow::{Context, Result};
use ethers::abi::ParamType;
use nested_params::{flatten_event_inputs, FlattenedEventParam, ParamIndex};
use serde::Serialize;
use std::path::PathBuf;

///The struct that houses all the details of each contract necessary for
///populating the contract import templates
#[derive(Serialize)]
pub struct AutoSchemaHandlerTemplate {
    imported_contracts: Vec<Contract>,
    hypersync_api_token: Option<String>,
}

impl TryInto<Schema> for AutoSchemaHandlerTemplate {
    type Error = anyhow::Error;
    fn try_into(self) -> Result<Schema, Self::Error> {
        let entities = self
            .imported_contracts
            .into_iter()
            .map(|c| c.try_into())
            .collect::<anyhow::Result<Vec<Schema>>>()?
            .into_iter()
            .flat_map(|s| s.entities.clone().into_values())
            .collect::<Vec<_>>();
        Schema::new(entities, vec![])
    }
}

#[derive(Serialize)]
pub struct Contract {
    name: CapitalizedOptions,
    imported_events: Vec<Event>,
}

impl Contract {
    fn from_config_contract(
        contract: &system_config::Contract,
        is_fuel: bool,
        language: &Language,
    ) -> Result<Self> {
        let imported_events = contract
            .events
            .iter()
            .map(|event| Event::from_config_event(event, &contract, is_fuel, &language))
            .collect::<Result<_>>()
            .context(format!(
                "Failed getting events for contract {}",
                contract.name
            ))?;

        Ok(Contract {
            name: contract.name.to_capitalized_options(),
            imported_events,
        })
    }
}

impl TryInto<Schema> for Contract {
    type Error = anyhow::Error;
    fn try_into(self) -> Result<Schema, Self::Error> {
        let entities = self.imported_events.into_iter().map(|e| e.into()).collect();
        Schema::new(entities, vec![])
    }
}

#[derive(Serialize)]
pub struct Event {
    name: CapitalizedOptions,
    entity_id_from_event_code: String,
    create_mock_code: String,
    params: Vec<Param>,
}

impl Event {
    fn get_entity_id_code(event_var_name: String, is_fuel: bool, language: &Language) -> String {
        let to_string_code = match language {
            Language::ReScript => "->Belt.Int.toString",
            Language::TypeScript => "",
            Language::JavaScript => "",
        }
        .to_string();
        match is_fuel {
            true => format!(
                "`${{{event_var_name}.transactionId}}_${{{event_var_name}.receiptIndex{}}}`",
                to_string_code
            ),
            false => format!(
                "`${{{event_var_name}.transactionHash}}_${{{event_var_name}.logIndex{}}}`",
                to_string_code
            ),
        }
    }

    fn get_create_mock_code(
        event: &system_config::Event,
        contract: &system_config::Contract,
        is_fuel: bool,
        language: &Language,
    ) -> String {
        let event_module = format!(
            "{}.{}",
            contract.name.capitalize(),
            event.get_event().name.capitalize()
        );
        match is_fuel {
            true => {
                let data_code = match language {
                    Language::ReScript => "%raw(`{}`)",
                    Language::TypeScript => "{}",
                    Language::JavaScript => "{}",
                };
                format!(
                    "{event_module}.mock({{data: {data_code} /* It mocks event fields with \
                     default values, so you only need to provide data */}})"
                )
            } // FIXME: Generate default data
            false => format!(
                "{event_module}.createMockEvent({{/* It mocks event fields with default values. \
                 You can overwrite them if you need */}})"
            ),
        }
    }

    fn from_config_event(
        event: &system_config::Event,
        contract: &system_config::Contract,
        is_fuel: bool,
        language: &Language,
    ) -> Result<Self> {
        let abi_event = event.get_event();
        let params = flatten_event_inputs(abi_event.inputs.clone())
            .into_iter()
            .map(|input| Param::from_event_param(input))
            .collect::<Result<_>>()
            .context(format!(
                "Failed getting params for event {}",
                abi_event.name
            ))?;

        Ok(Event {
            name: abi_event.name.to_capitalized_options(),
            entity_id_from_event_code: Event::get_entity_id_code(
                "event".to_string(),
                is_fuel,
                &language,
            ),
            create_mock_code: Event::get_create_mock_code(&event, &contract, is_fuel, &language),
            params,
        })
    }
}

impl Into<Entity> for Event {
    fn into(self) -> Entity {
        let fields = self
            .params
            .into_iter()
            .map(|p| (p.event_key.original.clone(), p.into()))
            .collect();
        Entity {
            name: self.name.original,
            fields,
            multi_field_indexes: vec![], // when doing contract import - entities won't have indexes by default.
        }
    }
}

///Param is used both in the context of an entity and an event for the generating
///schema and handlers.
#[derive(Serialize, Clone)]
pub struct Param {
    res_name: String,
    js_name: String,
    ///Event param name + index if its a tuple ie. myTupleParam_0_1 or just myRegularParam
    entity_key: CapitalizedOptions,
    ///Just the event param name accessible on the event type
    event_key: CapitalizedOptions,
    ///List of nested acessors so for a nested tuple Some([0, 1]) this can be used combined with
    ///the event key ie. event.params.myTupleParam[0][1]
    tuple_param_accessor_indexes: Option<Vec<ParamIndex>>,
    graphql_type: FieldType,
    is_eth_address: bool,
}

impl Param {
    fn make_res_name(js_name: &String) -> String {
        let uncapitalized = js_name.uncapitalize();
        if RESCRIPT_RESERVED_WORDS.contains(&uncapitalized.as_str()) {
            format!("{}_", uncapitalized)
        } else {
            uncapitalized
        }
    }

    fn from_event_param(flattened_event_param: FlattenedEventParam) -> Result<Self> {
        let js_name = flattened_event_param.event_param.name.to_string();
        let res_name = Self::make_res_name(&js_name);
        Ok(Param {
            res_name,
            js_name,
            entity_key: flattened_event_param.get_entity_key(),
            event_key: flattened_event_param.get_event_param_key(),
            tuple_param_accessor_indexes: flattened_event_param.accessor_indexes,
            graphql_type: FieldType::from_ethabi_type(&flattened_event_param.event_param.kind)
                .context(format!(
                    "Converting eth event param '{}' to gql scalar",
                    flattened_event_param.event_param.name
                ))?,
            is_eth_address: flattened_event_param.event_param.kind == ParamType::Address,
        })
    }
}

impl Into<Field> for Param {
    fn into(self) -> Field {
        Field {
            name: self.entity_key.original,
            field_type: self.graphql_type,
        }
    }
}

impl AutoSchemaHandlerTemplate {
    pub fn try_from(
        config: SystemConfig,
        is_fuel: bool,
        language: &Language,
        hypersync_api_token: Option<String>,
    ) -> Result<Self> {
        let imported_contracts = config
            .get_contracts()
            .iter()
            .map(|contract| Contract::from_config_contract(contract, is_fuel, &language))
            .collect::<Result<_>>()?;
        Ok(AutoSchemaHandlerTemplate {
            imported_contracts,
            hypersync_api_token,
        })
    }

    pub fn generate_contract_import_templates(
        &self,
        lang: &Language,
        project_root: &PathBuf,
    ) -> Result<()> {
        let template_dirs = TemplateDirs::new();

        let shared_dir = template_dirs
            .get_contract_import_shared_dir()
            .context("Failed getting shared contract import templates")?;

        let lang_dir = template_dirs
            .get_contract_import_lang_dir(lang)
            .context(format!("Failed getting {} contract import templates", lang))?;

        let hbs = HandleBarsDirGenerator::new(&lang_dir, &self, &project_root);
        let hbs_shared = HandleBarsDirGenerator::new(&shared_dir, &self, &project_root);
        hbs.generate_hbs_templates().context(format!(
            "Failed generating {} contract import templates",
            lang
        ))?;
        hbs_shared
            .generate_hbs_templates()
            .context("Failed generating shared contract import templates")?;

        Ok(())
    }

    pub fn generate_subgraph_migration_templates(
        &self,
        lang: &Language,
        project_root: &PathBuf,
    ) -> Result<()> {
        let template_dirs = TemplateDirs::new();

        let lang_dir = template_dirs
            .get_subgraph_migration_lang_dir(lang)
            .context(format!(
                "Failed getting {} subgraph migration templates",
                lang
            ))?;

        let hbs = HandleBarsDirGenerator::new(&lang_dir, &self, &project_root);

        hbs.generate_hbs_templates().context(format!(
            "Failed generating {} subgraph migration templates",
            lang
        ))?;

        Ok(())
    }
}

#[cfg(test)]
mod test {
    use super::*;
    use ethers::abi::EventParam;

    #[test]
    fn flatten_event_with_tuple() {
        let event_inputs = vec![
            EventParam {
                name: "user".to_string(),
                kind: ParamType::Address,
                indexed: false,
            },
            EventParam {
                name: "myTupleParam".to_string(),
                kind: ParamType::Tuple(vec![ParamType::Uint(256), ParamType::Bool]),
                indexed: false,
            },
        ];

        let expected_flat_inputs = vec![
            FlattenedEventParam::new("user", ParamType::Address, false, vec![], 0),
            FlattenedEventParam::new("myTupleParam", ParamType::Uint(256), false, vec![0], 1),
            FlattenedEventParam::new("myTupleParam", ParamType::Bool, false, vec![1], 1),
        ];

        let actual_flat_inputs = flatten_event_inputs(event_inputs);
        assert_eq!(expected_flat_inputs, actual_flat_inputs);

        let expected_entity_keys: Vec<_> = vec!["user", "myTupleParam_0", "myTupleParam_1"]
            .into_iter()
            .map(|s| s.to_string().to_capitalized_options())
            .collect();

        let actual_entity_keys: Vec<_> = actual_flat_inputs
            .iter()
            .map(|f| f.get_entity_key())
            .collect();

        assert_eq!(expected_entity_keys, actual_entity_keys);
    }

    #[test]
    fn flatten_event_with_nested_tuple() {
        let event_inputs = vec![
            EventParam {
                //nameless param should compute to "_0"
                name: "".to_string(),
                kind: ParamType::Address,
                indexed: false,
            },
            EventParam {
                name: "myTupleParam".to_string(),
                kind: ParamType::Tuple(vec![
                    ParamType::Tuple(vec![ParamType::Uint(8), ParamType::Uint(8)]),
                    ParamType::Bool,
                ]),
                indexed: false,
            },
            EventParam {
                //param named "id" should compute to "event_id"
                name: "id".to_string(),
                kind: ParamType::String,
                indexed: false,
            },
        ];

        let expected_flat_inputs = vec![
            FlattenedEventParam::new("", ParamType::Address, false, vec![], 0),
            FlattenedEventParam::new("myTupleParam", ParamType::Uint(8), false, vec![0, 0], 1),
            FlattenedEventParam::new("myTupleParam", ParamType::Uint(8), false, vec![0, 1], 1),
            FlattenedEventParam::new("myTupleParam", ParamType::Bool, false, vec![1], 1),
            FlattenedEventParam::new("id", ParamType::String, false, vec![], 2),
        ];
        let actual_flat_inputs = flatten_event_inputs(event_inputs);
        assert_eq!(expected_flat_inputs, actual_flat_inputs);

        // test that `entity_key`s are correct
        let expected_entity_keys: Vec<_> = vec![
            "_0",
            "myTupleParam_0_0",
            "myTupleParam_0_1",
            "myTupleParam_1",
            "event_id",
        ]
        .into_iter()
        .map(|s| s.to_string().to_capitalized_options())
        .collect();

        let actual_entity_keys: Vec<_> = actual_flat_inputs
            .iter()
            .map(|f| f.get_entity_key())
            .collect();

        assert_eq!(expected_entity_keys, actual_entity_keys);

        // test that `event_key`s are correct
        let expected_event_keys: Vec<_> =
            vec!["_0", "myTupleParam", "myTupleParam", "myTupleParam", "id"]
                .into_iter()
                .map(|s| s.to_string().to_capitalized_options())
                .collect();

        let actual_event_keys: Vec<_> = actual_flat_inputs
            .iter()
            .map(|f| f.get_event_param_key())
            .collect();

        assert_eq!(expected_event_keys, actual_event_keys);
    }
}
