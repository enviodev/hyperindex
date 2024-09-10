mod evm_prompts;
mod fuel_prompts;
mod inquire_helpers;
mod shared_prompts;
pub mod validation;

use super::{
    clap_definitions::{self, InitArgs, ProjectPaths},
    init_config::{InitConfig, Language},
};
use crate::{
    clap_definitions::InitFlow,
    constants::project_paths::DEFAULT_PROJECT_ROOT_PATH,
    init_config::{evm, Ecosystem},
};
use anyhow::{Context, Result};
use inquire::{Select, Text};
use shared_prompts::prompt_template;
use std::str::FromStr;
use strum;
use strum::{Display, EnumIter, IntoEnumIterator};
use validation::{
    contains_no_whitespace_validator, is_directory_new_validator,
    is_valid_foldername_inquire_validator,
};

#[derive(Clone, Debug, Display, PartialEq, EnumIter)]
enum EcosystemOption {
    Evm,
    Fuel,
}

async fn prompt_ecosystem(cli_init_flow: Option<InitFlow>) -> Result<Ecosystem> {
    let init_flow = match cli_init_flow {
        Some(v) => v,
        None => {
            let ecosystem_options = EcosystemOption::iter().collect();

            let ecosystem_option = Select::new("Choose blockchain ecosystem", ecosystem_options)
                .prompt()
                .context("Failed prompting for blockchain ecosystem")?;

            match ecosystem_option {
                EcosystemOption::Fuel => InitFlow::Fuel { init_flow: None },
                EcosystemOption::Evm => {
                    // Start prompt to ask the user which initialization option they want
                    // Explicitelly build options, since we don't want to include graph migration and other ecosystem selection subcomands
                    let user_response_options =
                        clap_definitions::EvmInitFlowInteractive::iter().collect();

                    Select::new("Choose an initialization option", user_response_options)
                        .prompt()
                        .context("Failed prompting for Evm initialization option")?
                        .into()
                }
            }
        }
    };

    let initialization = match init_flow {
        InitFlow::Fuel {
            init_flow: maybe_init_flow,
        } => match fuel_prompts::prompt_init_flow_missing(maybe_init_flow)? {
            clap_definitions::fuel::InitFlow::Template(args) => Ecosystem::Fuel {
                init_flow: fuel_prompts::prompt_template_init_flow(args)?,
            },
            clap_definitions::fuel::InitFlow::ContractImport(args) => Ecosystem::Fuel {
                init_flow: fuel_prompts::prompt_contract_import_init_flow(args).await?,
            },
        },
        InitFlow::Template(args) => {
            let chosen_template = match args.template {
                Some(template) => template,
                None => {
                    let options = evm::Template::iter().collect();
                    prompt_template(options)?
                }
            };
            Ecosystem::Evm {
                init_flow: evm::InitFlow::Template(chosen_template),
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
                init_flow: evm::InitFlow::SubgraphID(input_subgraph_id),
            }
        }

        InitFlow::ContractImport(args) => Ecosystem::Evm {
            init_flow: evm_prompts::prompt_contract_import_init_flow(args).await?,
        },
    };

    Ok(initialization)
}

#[derive(Debug, Clone, strum::Display, strum::EnumIter, strum::EnumString)]
enum ApiTokenInput {
    #[strum(serialize = "Create a new API token (Opens https://envio.dev/app/api-tokens)")]
    Create,
    #[strum(serialize = "Add an existing API token")]
    AddExisting,
    #[strum(serialize = "Skip for now, I'll add later")]
    Skip,
}
pub async fn prompt_missing_init_args(
    init_args: InitArgs,
    project_paths: &ProjectPaths,
) -> Result<InitConfig> {
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

    let name: String = match init_args.name {
        Some(args_name) => args_name,
        None => {
            if directory == DEFAULT_PROJECT_ROOT_PATH {
                "envio-indexer".to_string()
            } else {
                directory.to_string()
            }
        }
    };

    let language = match init_args.language {
        Some(args_language) => args_language,
        None => {
            let options = Language::iter()
                .map(|language| language.to_string())
                .collect::<Vec<String>>();

            let input_language = Select::new("Which language would you like to use?", options)
                .with_starting_cursor(1)
                .prompt()
                .context("prompting user to select language")?;

            Language::from_str(&input_language)
                .context("parsing user input for language selection")?
        }
    };

    let ecosystem = prompt_ecosystem(init_args.init_commands)
        .await
        .context("Failed getting template")?;

    let api_token: Option<String> = match init_args.api_token {
        Some(k) => Ok::<_, anyhow::Error>(Some(k)),
        None if ecosystem.uses_hypersync() => {
            let select = Select::new(
                "Add an API token for HyperSync to your .env file?",
                ApiTokenInput::iter().collect(),
            )
            .prompt()
            .context("Prompting for add API token")?;

            let token_prompt = Text::new("Add your API token: ")
                .with_help_message("See tokens at: https://envio.dev/app/api-tokens");

            match select {
                ApiTokenInput::Create => {
                    open::that_detached("https://envio.dev/app/api-tokens")?;
                    Ok(token_prompt
                        .prompt_skippable()
                        .context("Prompting for create token")?)
                }
                ApiTokenInput::AddExisting => Ok(token_prompt
                    .prompt_skippable()
                    .context("Prompting for add existing token")?),
                ApiTokenInput::Skip => {
                    println!(
                        "You can always visit 'https://envio.dev/app/api-tokens' and add a token \
                         later to your .env file."
                    );
                    Ok(None)
                }
            }
        }
        None => Ok(None),
    }
    .context("Prompting for API Token")?;

    Ok(InitConfig {
        name,
        directory,
        ecosystem,
        language,
        api_token,
    })
}
