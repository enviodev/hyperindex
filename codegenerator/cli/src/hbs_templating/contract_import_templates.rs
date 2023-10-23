use super::hbs_dir_generator::HandleBarsDirGenerator;
use anyhow::{anyhow, Context, Result};
use ethers::abi::{EventParam, ParamType};
use include_dir::{include_dir, Dir};
use serde::Serialize;
use std::path::PathBuf;

use crate::capitalization::{Capitalize, CapitalizedOptions};
use crate::config_parsing::config::{self, Config, Contract as ConfigContract};
use crate::config_parsing::entity_parsing::{
    ethabi_type_to_field_type, Entity, Field, FieldType, Schema,
};

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
    fn from_config_contract(contract: &ConfigContract) -> Result<Self> {
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
    fn from_config_event(e: &config::Event) -> Result<Self> {
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
    pub fn try_from(config: Config) -> Result<Self> {
        let contracts = config
            .get_contracts()
            .iter()
            .map(|c| Contract::from_config_contract(c))
            .collect::<Result<_>>()?;
        Ok(AutoSchemaHandlerTemplate { contracts })
    }

    fn generate_templates(&self, project_root: &PathBuf, template_dir: &Dir<'_>) -> Result<()> {
        static SHARED_DIR: Dir<'_> =
            include_dir!("$CARGO_MANIFEST_DIR/templates/dynamic/contract_import_templates/shared");

        let hbs = HandleBarsDirGenerator::new(&template_dir, &self, &project_root);
        let hbs_shared = HandleBarsDirGenerator::new(&SHARED_DIR, &self, &project_root);
        hbs.generate_hbs_templates().map_err(|e| anyhow!("{}", e))?;
        hbs_shared
            .generate_hbs_templates()
            .map_err(|e| anyhow!("{}", e))?;

        Ok(())
    }

    pub fn generate_templates_typescript(&self, project_root: &PathBuf) -> Result<()> {
        static DIR: Dir<'_> = include_dir!(
            "$CARGO_MANIFEST_DIR/templates/dynamic/contract_import_templates/typescript"
        );

        self.generate_templates(project_root, &DIR)
    }

    pub fn generate_templates_javascript(&self, project_root: &PathBuf) -> Result<()> {
        static DIR: Dir<'_> = include_dir!(
            "$CARGO_MANIFEST_DIR/templates/dynamic/contract_import_templates/javascript"
        );

        self.generate_templates(project_root, &DIR)
    }

    pub fn generate_templates_rescript(&self, project_root: &PathBuf) -> Result<()> {
        static DIR: Dir<'_> = include_dir!(
            "$CARGO_MANIFEST_DIR/templates/dynamic/contract_import_templates/rescript"
        );

        self.generate_templates(project_root, &DIR)
    }
}
