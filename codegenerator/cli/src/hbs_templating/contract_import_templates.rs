use super::hbs_dir_generator::HandleBarsDirGenerator;
use crate::{
    capitalization::{Capitalize, CapitalizedOptions},
    cli_args::clap_definitions::Language,
    config_parsing::{
        entity_parsing::{ethabi_type_to_field_type, Entity, Field, FieldType, Schema},
        system_config::{self, SystemConfig},
    },
    template_dirs::TemplateDirs,
};
use anyhow::{Context, Result};
use ethers::abi::{EventParam, ParamType};
use serde::Serialize;
use std::path::PathBuf;

#[derive(Serialize)]
pub struct AutoSchemaHandlerTemplate {
    contracts: Vec<Contract>,
}

impl Into<Schema> for AutoSchemaHandlerTemplate {
    fn into(self) -> Schema {
        let entities = self
            .contracts
            .into_iter()
            .flat_map(|c| {
                let schema: Schema = c.into();
                schema.entities
            })
            .collect();
        Schema { entities }
    }
}

#[derive(Serialize)]
pub struct Contract {
    name: CapitalizedOptions,
    events: Vec<Event>,
}

impl Contract {
    fn from_config_contract(contract: &system_config::Contract) -> Result<Self> {
        let events = contract
            .events
            .iter()
            .map(|event| Event::from_config_event(event))
            .collect::<Result<_>>()
            .context(format!(
                "Failed getting events for contract {}",
                contract.name
            ))?;

        Ok(Contract {
            name: contract.name.to_capitalized_options(),
            events,
        })
    }
}

impl Into<Schema> for Contract {
    fn into(self) -> Schema {
        let entities = self.events.into_iter().map(|e| e.into()).collect();
        Schema { entities }
    }
}

#[derive(Serialize)]
pub struct Event {
    name: CapitalizedOptions,
    params: Vec<Param>,
}

///Take an event, and if any param is a tuple type,
///it flattens it into an event with more params
///MyEvent(address myAddress, (uint256, bool) myTupleParam) ->
///MyEvent(address myAddress, uint256 myTupleParam_1, uint256 myTupleParam_2)
///This representation makes it easy to have single field conversions
fn flatten_event_inputs(
    event_inputs: Vec<ethers::abi::EventParam>,
) -> Vec<ethers::abi::EventParam> {
    event_inputs
        .into_iter()
        .flat_map(|event_input| {
            if let ParamType::Tuple(param_types) = event_input.kind {
                let event_inputs = param_types
                    .into_iter()
                    .enumerate()
                    .map(|(i, p)| ethers::abi::EventParam {
                        /// Param name. becomes tupleParamame_1 for eg.
                        name: format!("{}_{}", event_input.name, i + 1),
                        kind: p,
                        indexed: false,
                    })
                    .collect();
                flatten_event_inputs(event_inputs)
            } else {
                vec![event_input]
            }
        })
        .collect()
}

impl Event {
    fn from_config_event(e: &system_config::Event) -> Result<Self> {
        let params = flatten_event_inputs(e.event.inputs.clone())
            .iter()
            .map(|input| Param::from_event_param(input))
            .collect::<Result<_>>()
            .context(format!("Failed getting params for event {}", e.event.name))?;

        Ok(Event {
            name: e.event.name.to_capitalized_options(),
            params,
        })
    }
}

impl Into<Entity> for Event {
    fn into(self) -> Entity {
        let fields = self.params.into_iter().map(|p| p.into()).collect();
        Entity {
            name: self.name.original,
            fields,
        }
    }
}

#[derive(Serialize)]
pub struct Param {
    key: CapitalizedOptions,
    graphql_type: FieldType,
    is_eth_address: bool,
}

impl Param {
    fn from_event_param(event_param: &EventParam) -> Result<Self> {
        Ok(Param {
            key: event_param.name.to_capitalized_options(),
            graphql_type: ethabi_type_to_field_type(&event_param.kind)
                .context("converting eth event param to gql scalar")?,
            is_eth_address: event_param.kind == ParamType::Address,
        })
    }
}

impl Into<Field> for Param {
    fn into(self) -> Field {
        Field {
            name: self.key.original,
            field_type: self.graphql_type,
            derived_from_field: None,
        }
    }
}

impl AutoSchemaHandlerTemplate {
    pub fn try_from(config: SystemConfig) -> Result<Self> {
        let contracts = config
            .get_contracts()
            .iter()
            .map(|c| Contract::from_config_contract(c))
            .collect::<Result<_>>()?;
        Ok(AutoSchemaHandlerTemplate { contracts })
    }

    pub fn generate_templates(&self, lang: &Language, project_root: &PathBuf) -> Result<()> {
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
            EventParam {
                name: "user".to_string(),
                kind: ParamType::Address,
                indexed: false,
            },
            EventParam {
                name: "myTupleParam_1".to_string(),
                kind: ParamType::Uint(256),
                indexed: false,
            },
            EventParam {
                name: "myTupleParam_2".to_string(),
                kind: ParamType::Bool,
                indexed: false,
            },
        ];

        assert_eq!(expected_flat_inputs, flatten_event_inputs(event_inputs));
    }

    #[test]
    fn flatten_event_with_nested_tuple() {
        let event_inputs = vec![
            EventParam {
                name: "user".to_string(),
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
        ];

        let expected_flat_inputs = vec![
            EventParam {
                name: "user".to_string(),
                kind: ParamType::Address,
                indexed: false,
            },
            EventParam {
                name: "myTupleParam_1_1".to_string(),
                kind: ParamType::Uint(8),
                indexed: false,
            },
            EventParam {
                name: "myTupleParam_1_2".to_string(),
                kind: ParamType::Uint(8),
                indexed: false,
            },
            EventParam {
                name: "myTupleParam_2".to_string(),
                kind: ParamType::Bool,
                indexed: false,
            },
        ];

        assert_eq!(expected_flat_inputs, flatten_event_inputs(event_inputs));
    }
}
