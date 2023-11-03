use super::hbs_dir_generator::HandleBarsDirGenerator;
use crate::{
    capitalization::{Capitalize, CapitalizedOptions},
    cli_args::Language,
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

impl Event {
    fn from_config_event(e: &system_config::Event) -> Result<Self> {
        let params = e
            .event
            .inputs
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
