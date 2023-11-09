use super::{
    validation::{is_directory_new, is_valid_foldername_inquire_validation_result},
    InitArgs, InitFlow, Language, ProjectPaths, Template as InitTemplate,
};
use crate::{
    config_parsing::chain_helpers::{NetworkWithExplorer, SupportedNetwork},
    constants::project_paths::DEFAULT_PROJECT_ROOT_PATH,
    utils::address_type::Address,
};
use anyhow::{Context, Result};
use inquire::{Select, Text};
use std::str::FromStr;
use strum::IntoEnumIterator;

#[derive(Clone)]
pub enum InitilizationTypeWithArgs {
    Template(InitTemplate),
    SubgraphID(String),
    ContractImportWithArgs(NetworkWithExplorer, Address),
}

#[derive(Clone)]
pub struct InitInteractive {
    pub name: String,
    pub directory: String,
    pub template: InitilizationTypeWithArgs,
    pub language: Language,
}

impl InitArgs {
    pub fn get_init_args_interactive(
        &self,
        project_paths: &ProjectPaths,
    ) -> Result<InitInteractive> {
        let name: String = match &self.name {
            Some(args_name) => args_name.clone(),
            None => {
                // todo input validation for name

                Text::new("Name your indexer: ").prompt()?
            }
        };

        let directory: String = match &project_paths.directory {
            Some(args_directory) => args_directory.clone(),
            None => {
                Text::new("Specify a folder name (ENTER to skip): ")
                    .with_default(DEFAULT_PROJECT_ROOT_PATH)
                    // validate string is valid directory name
                    .with_validator(is_valid_foldername_inquire_validation_result)
                    // validate the directory doesn't already exist
                    .with_validator(is_directory_new)
                    .prompt()?
            }
        };

        let template: InitilizationTypeWithArgs = get_init_args(&self.init_commands)?;

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

        Ok(InitInteractive {
            name,
            directory,
            template,
            language,
        })
    }
}

fn get_init_args(opt_init_flow: &Option<InitFlow>) -> Result<InitilizationTypeWithArgs> {
    match opt_init_flow {
        Some(init_flow) => {
            let initialization = match init_flow {
                InitFlow::Template(args) => {
                    let chosen_template = match &args.template {
                        Some(template_name) => template_name.clone(),
                        None => {
                            let options = InitTemplate::iter()
                                .map(|template| template.to_string())
                                .collect::<Vec<String>>();

                            let user_response =
                                Select::new("Which template would you like to use?", options)
                                    .prompt()
                                    .context("Prompting user for template selection")?;

                            InitTemplate::from_str(&user_response)
                                .context("parsing InitTemplate from user response string")?
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
                    let chosen_network = match &args.blockchain {
                        Some(chain) => chain.clone(),
                        None => {
                            let options = NetworkWithExplorer::iter()
                                //Filter only our supported networks
                                .filter(|&n| {
                                    SupportedNetwork::iter()
                                        //able to cast as u64 because networks enum
                                        //uses repr(u64) attribute
                                        .find(|&sn| n as u64 == sn as u64)
                                        .is_some()
                                })
                                .map(|network| network.to_string())
                                .collect::<Vec<String>>();

                            let input_network = Select::new(
                                "Which blockchain would you like to import a contract from?",
                                options,
                            )
                            .prompt()?;

                            NetworkWithExplorer::from_str(&input_network)
                                .context("Parsing network from user selected network name")?
                        }
                    };

                    let chosen_contract_address = match &args.contract_address {
                        Some(c) => c.clone(),
                        None => {
                            let mut address_str =
                                Text::new("[BETA VERSION] What is the address of the contract?")
                                    .prompt()
                                    .context("Prompting user for contract address")?;

                            loop {
                                match address_str.as_str().parse() {
                                    Ok(parsed_val) => break parsed_val,
                                    Err(_) => {
                                        address_str = Text::new(
                                            "Invalid contract address input, please try again",
                                        )
                                        .prompt()
                                        .context("Re-prompting user for valid contract address")?;
                                    }
                                }
                            }
                        }
                    };

                    InitilizationTypeWithArgs::ContractImportWithArgs(
                        chosen_network,
                        chosen_contract_address,
                    )
                }
            };

            Ok(initialization)
        }
        None => {
            //start prompt to ask the user which initialization option they want
            let user_response_options = InitFlow::iter()
                .map(|init_cmd| init_cmd.to_string())
                .collect::<Vec<String>>();

            let user_response =
                Select::new("Choose an initialization option", user_response_options).prompt()?;

            let chosen_init_option = InitFlow::from_str(&user_response)
                .context("Parsing InitFlow from user input string")?;

            get_init_args(&Some(chosen_init_option))
        }
    }
}
