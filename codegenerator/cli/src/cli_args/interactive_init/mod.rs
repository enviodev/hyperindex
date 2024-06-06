mod contract_import_prompts;
mod inquire_helpers;
pub mod validation;

use std::fmt::Display;

use super::{
    clap_definitions::{self, InitArgs, InitFlow, ProjectPaths},
    init_config::{self, Ecosystem, EvmInitFlow, FuelInitFlow, InitConfig, Language},
};
use crate::constants::project_paths::DEFAULT_PROJECT_ROOT_PATH;
use anyhow::{Context, Result};
use inquire::{Select, Text};
use std::str::FromStr;
use strum::{Display, EnumIter, IntoEnumIterator};
use validation::{
    contains_no_whitespace_validator, is_directory_new_validator, is_not_empty_string_validator,
    is_valid_foldername_inquire_validator,
};

#[derive(Clone, Debug, Display, PartialEq, EnumIter)]
pub enum EcosystemOption {
    Evm,
    Fuel,
}

fn prompt_template<T: Display>(options: Vec<T>) -> Result<T> {
    Select::new("Which template would you like to use?", options)
        .prompt()
        .context("Prompting user for template selection")
}

async fn prompt_ecosystem(
    cli_init_flow: Option<InitFlow>,
    project_name: String,
    language: Language,
) -> Result<Ecosystem> {
    let init_flow = match cli_init_flow {
        Some(v) => v,
        None => {
            let ecosystem_options = EcosystemOption::iter().collect();

            let ecosystem_option = Select::new("Choose blockchain ecosystem", ecosystem_options)
                .prompt()
                .context("Failed prompting for blockchain ecosystem")?;

            match ecosystem_option {
                EcosystemOption::Fuel => {
                    let flow_option = clap_definitions::FuelInitFlow::iter().collect();
                    let fuel_init_flow =
                        Select::new("Choose an initialization option", flow_option)
                            .prompt()
                            .context("Failed prompting for Fuel initialization option")?;
                    InitFlow::Fuel(fuel_init_flow)
                }
                EcosystemOption::Evm => {
                    // start prompt to ask the user which initialization option they want
                    let user_response_options = InitFlow::iter()
                        // Filter out subgraph migration for now until stabilized
                        // And don't include different ecosystem options
                        .filter(|v| {
                            matches!(v, InitFlow::Template(_))
                                || matches!(v, InitFlow::ContractImport(_))
                        })
                        .collect();
                    Select::new("Choose an initialization option", user_response_options)
                        .prompt()
                        .context("Failed prompting for Evm initialization option")?
                }
            }
        }
    };

    let initialization = match init_flow {
        InitFlow::Fuel(clap_definitions::FuelInitFlow::Template(args)) => {
            let chosen_template = match args.template {
                Some(template) => template,
                None => {
                    let options = clap_definitions::FuelTemplate::iter().collect();
                    prompt_template(options)?
                }
            };
            Ecosystem::Fuel {
                init_flow: FuelInitFlow::Template(match chosen_template {
                    clap_definitions::FuelTemplate::Greeter => init_config::FuelTemplate::Greeter,
                }),
            }
        }
        InitFlow::Template(args) => {
            let chosen_template = match args.template {
                Some(template) => template,
                None => {
                    let options = clap_definitions::EvmTemplate::iter().collect();
                    prompt_template(options)?
                }
            };
            Ecosystem::Evm {
                init_flow: EvmInitFlow::Template(match chosen_template {
                    clap_definitions::EvmTemplate::Greeter => init_config::EvmTemplate::Greeter,
                    clap_definitions::EvmTemplate::Erc20 => init_config::EvmTemplate::Erc20,
                }),
            }
        }
        InitFlow::SubgraphMigration(args) => {
            let input_subgraph_id = match args.subgraph_id {
                Some(id) => id,
                None => Text::new("[BETA VERSION] What is the subgraph ID?")
                    .prompt()
                    .context("Prompting user for subgraph id")?,
            };
            Ecosystem::Evm {
                init_flow: EvmInitFlow::SubgraphID(input_subgraph_id),
            }
        }

        InitFlow::ContractImport(args) => {
            let auto_config_selection = args
                .get_auto_config_selection(project_name, language)
                .await
                .context("Failed getting AutoConfigSelection selection")?;
            Ecosystem::Evm {
                init_flow: EvmInitFlow::ContractImportWithArgs(auto_config_selection),
            }
        }
    };

    Ok(initialization)
}

pub async fn prompt_missing_init_args(
    init_args: InitArgs,
    project_paths: &ProjectPaths,
) -> Result<InitConfig> {
    let name: String = match init_args.name {
        Some(args_name) => args_name,
        None => {
            // TODO: input validation for name
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

    let language = match init_args.language {
        Some(args_language) => args_language,
        None => {
            let options = clap_definitions::Language::iter()
                .map(|language| language.to_string())
                .collect::<Vec<String>>();

            let input_language = Select::new("Which language would you like to use?", options)
                .with_starting_cursor(1)
                .prompt()
                .context("prompting user to select language")?;

            clap_definitions::Language::from_str(&input_language)
                .context("parsing user input for language selection")?
        }
    };
    let language = match language {
        clap_definitions::Language::JavaScript => Language::JavaScript,
        clap_definitions::Language::TypeScript => Language::TypeScript,
        clap_definitions::Language::ReScript => Language::ReScript,
    };

    let ecosystem = prompt_ecosystem(init_args.init_commands, name.clone(), language.clone())
        .await
        .context("Failed getting template")?;

    Ok(InitConfig {
        name,
        directory,
        ecosystem,
        language,
    })
}
