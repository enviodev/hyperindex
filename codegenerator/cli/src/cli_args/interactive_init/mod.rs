mod contract_import_prompts;
mod inquire_helpers;
pub mod validation;

use super::clap_definitions::{
    self, InitArgs, InitFlow, Language, ProjectPaths, Template as InitTemplate,
};
use crate::{
    config_parsing::contract_import::converters::AutoConfigSelection,
    constants::project_paths::DEFAULT_PROJECT_ROOT_PATH,
};
use anyhow::{Context, Result};
use inquire::{Select, Text};
use std::str::FromStr;
use strum::IntoEnumIterator;
use validation::{
    contains_no_whitespace_validator, is_directory_new_validator, is_not_empty_string_validator,
    is_valid_foldername_inquire_validator,
};

#[derive(Clone)]
pub enum InitilizationTypeWithArgs {
    Template(InitTemplate),
    SubgraphID(String),
    ContractImportWithArgs(AutoConfigSelection),
}

#[derive(Clone)]
pub struct InitInteractive {
    pub name: String,
    pub directory: String,
    pub template: InitilizationTypeWithArgs,
    pub language: Language,
}

impl InitArgs {
    //Turns the cli init args with optional values into
    //fixed values via interactive prompts
    pub async fn get_init_args_interactive(
        &self,
        project_paths: &ProjectPaths,
    ) -> Result<InitInteractive> {
        let name: String = match &self.name {
            Some(args_name) => args_name.clone(),
            None => {
                // todo input validation for name
                Text::new("Name your indexer:")
                    .with_default("My Envio Indexer")
                    .with_validator(is_not_empty_string_validator)
                    .prompt()?
            }
        };

        let directory: String = match &project_paths.directory {
            Some(args_directory) => args_directory.clone(),
            None => {
                Text::new("Specify a folder name (ENTER to skip): ")
                    .with_default(DEFAULT_PROJECT_ROOT_PATH)
                    // validate string is valid directory name
                    .with_validator(is_valid_foldername_inquire_validator)
                    // validate the directory doesn't already exist
                    .with_validator(is_directory_new_validator)
                    .with_validator(contains_no_whitespace_validator)
                    .prompt()?
            }
        };

        let language = match &self.language {
            Some(args_language) => args_language.clone(),
            None => {
                let options = Language::iter()
                    .map(|language| language.to_string())
                    .collect::<Vec<String>>();

                let input_language = Select::new("Which language would you like to use?", options)
                    .prompt()
                    .context("prompting user to select language")?;

                Language::from_str(&input_language)
                    .context("parsing user input for language selection")?
            }
        };

        let init_flow = match &self.init_commands {
            Some(v) => v.clone(),
            None => {
                //start prompt to ask the user which initialization option they want
                let user_response_options = InitFlow::iter().collect();

                Select::new("Choose an initialization option", user_response_options)
                    .prompt()
                    .context("Failed prompting for initialization option")?
            }
        };

        let template = init_flow
            .get_init_args(name.clone(), language.clone())
            .await
            .context("Failed getting template")?;

        Ok(InitInteractive {
            name,
            directory,
            template,
            language,
        })
    }
}

impl InitFlow {
    async fn get_init_args(
        &self,
        project_name: String,
        language: Language,
    ) -> Result<InitilizationTypeWithArgs> {
        let initialization = match self {
            InitFlow::Template(args) => {
                let chosen_template = match &args.template {
                    Some(template_name) => template_name.clone(),
                    None => {
                        let options = InitTemplate::iter().collect();

                        Select::new("Which template would you like to use?", options)
                            .prompt()
                            .context("Prompting user for template selection")?
                    }
                };
                InitilizationTypeWithArgs::Template(chosen_template)
            }
            InitFlow::SubgraphMigration(args) => {
                let input_subgraph_id = match &args.subgraph_id {
                    Some(id) => id.clone(),
                    None => Text::new("[BETA VERSION] What is the subgraph ID?")
                        .prompt()
                        .context("Prompting user for subgraph id")?,
                };

                InitilizationTypeWithArgs::SubgraphID(input_subgraph_id)
            }

            InitFlow::ContractImport(args) => {
                let auto_config_selection = args
                    .get_auto_config_selection(project_name, language)
                    .await
                    .context("Failed getting AutoConfigSelection selection")?;

                InitilizationTypeWithArgs::ContractImportWithArgs(auto_config_selection)
            }
        };

        Ok(initialization)
    }
}
