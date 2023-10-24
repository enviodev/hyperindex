use super::hbs_dir_generator::HandleBarsDirGenerator;
use anyhow::{anyhow, Context};
use ethers::abi::ParamType;
use include_dir::{include_dir, Dir};
use serde::Serialize;
use std::path::PathBuf;

use crate::capitalization::{Capitalize, CapitalizedOptions};
use crate::config_parsing::entity_parsing::ethabi_type_to_scalar;
use crate::config_parsing::{Config, EventNameOrSig};

#[derive(Serialize)]
pub struct AutoSchemaHandlerTemplate {
    contracts: Vec<Contract>,
}

#[derive(Serialize)]
pub struct Contract {
    name: CapitalizedOptions,
    events: Vec<Event>,
}

#[derive(Serialize)]
pub struct Event {
    name: CapitalizedOptions,
    params: Vec<Param>,
}

#[derive(Serialize)]
pub struct Param {
    key: CapitalizedOptions,
    graphql_type: String,
    is_eth_address: bool,
}

impl AutoSchemaHandlerTemplate {
    pub fn try_from(config: Config) -> anyhow::Result<Self> {
        let mut contracts = Vec::new();
        // what about the scenario where there is the same contract that is defined for multiple chains?
        for network in config.networks.iter() {
            for contract in network.contracts.iter() {
                let contract_name = contract.name.to_capitalized_options();
                let mut events = Vec::new();

                for config_event in contract.events.iter() {
                    match &config_event.event {
                        EventNameOrSig::Name(_) => Err(anyhow!(
                            "Currently only handling config defined events (not external abi file)"
                        ))?,
                        EventNameOrSig::Event(event) => {
                            let event_name = event.name.to_capitalized_options();

                            let params: Vec<_> = event
                                .inputs
                                .iter()
                                .map(|param| {
                                    let graphql_type = ethabi_type_to_scalar(&param.kind)
                                        .context("converting eth event param to gql scalar")?
                                        .to_string();
                                    let param_name = param.name.to_capitalized_options();
                                    Ok(Param {
                                        key: param_name,
                                        graphql_type,
                                        is_eth_address: param.kind == ParamType::Address,
                                    })
                                })
                                .collect::<anyhow::Result<_>>()?;

                            events.push(Event {
                                name: event_name,
                                params,
                            });
                        }
                    };
                }
                contracts.push(Contract {
                    name: contract_name,
                    events,
                });
            }
        }
        Ok(AutoSchemaHandlerTemplate { contracts })
    }

    fn generate_templates(&self, project_root: &PathBuf, template_dir:&Dir<'_>) -> anyhow::Result<()> {
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

    pub fn generate_templates_typescript(&self, project_root: &PathBuf) -> anyhow::Result<()> {
        static DIR: Dir<'_> = include_dir!(
            "$CARGO_MANIFEST_DIR/templates/dynamic/contract_import_templates/typescript"
        ); 

        self.generate_templates(project_root, &DIR)
    }        

    pub fn generate_templates_javascript(&self, project_root: &PathBuf) -> anyhow::Result<()> {
        static DIR: Dir<'_> = include_dir!(
            "$CARGO_MANIFEST_DIR/templates/dynamic/contract_import_templates/javascript"
        ); 

        self.generate_templates(project_root, &DIR)
    }        

    pub fn generate_templates_rescript(&self, project_root: &PathBuf) -> anyhow::Result<()> {
        static DIR: Dir<'_> = include_dir!(
            "$CARGO_MANIFEST_DIR/templates/dynamic/contract_import_templates/rescript"
        ); 

        self.generate_templates(project_root, &DIR)
    }        
}
