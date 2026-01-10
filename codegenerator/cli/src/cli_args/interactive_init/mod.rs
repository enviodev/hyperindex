mod evm_prompts;
mod fuel_prompts;
mod inquire_helpers;
mod shared_prompts;
mod svm_prompts;
pub mod validation;

use super::{
    clap_definitions::{self, InitArgs, ProjectPaths},
    init_config::{InitConfig, Language},
};
use crate::{
    clap_definitions::InitFlow,
    constants::project_paths::DEFAULT_PROJECT_ROOT_PATH,
    init_config::{evm, fuel, Ecosystem},
};
use anyhow::{Context, Result};
use inquire::{Select, Text};
use strum;
use strum::{Display, EnumIter, IntoEnumIterator};
use validation::{
    contains_no_whitespace_validator, is_directory_new_validator,
    is_valid_foldername_inquire_validator,
};

#[derive(Clone, Debug, Display, PartialEq, EnumIter)]
enum EcosystemOption {
    Evm,
    Svm,
    Fuel,
}

/// Flattened EVM initialization options shown in a single prompt
#[derive(Clone, Debug, Display)]
enum EvmInitOption {
    #[strum(serialize = "From Address - Lookup ABI from block explorer")]
    ContractImportExplorer,
    #[strum(serialize = "From ABI File - Use your own ABI file")]
    ContractImportLocal,
    #[strum(serialize = "Template: ERC20")]
    TemplateErc20,
    #[strum(serialize = "Template: Greeter")]
    TemplateGreeter,
    #[strum(serialize = "Feature: Factory Contract")]
    FeatureFactory,
}

impl EvmInitOption {
    fn all_options(language: &Language) -> Vec<Self> {
        match language {
            // ReScript doesn't support templates/features, only contract import
            Language::ReScript => vec![Self::ContractImportExplorer, Self::ContractImportLocal],
            Language::TypeScript => vec![
                Self::ContractImportExplorer,
                Self::ContractImportLocal,
                Self::TemplateErc20,
                Self::TemplateGreeter,
                Self::FeatureFactory,
            ],
        }
    }
}

/// Flattened Fuel initialization options shown in a single prompt
#[derive(Clone, Debug, Display)]
enum FuelInitOption {
    #[strum(serialize = "From ABI File - Use your own ABI file")]
    ContractImportLocal,
    #[strum(serialize = "Template: Greeter")]
    TemplateGreeter,
}

impl FuelInitOption {
    fn all_options(language: &Language) -> Vec<Self> {
        match language {
            // ReScript doesn't support templates, only contract import
            Language::ReScript => vec![Self::ContractImportLocal],
            Language::TypeScript => vec![Self::ContractImportLocal, Self::TemplateGreeter],
        }
    }
}

/// Result of ecosystem prompt, including the ecosystem and effective language
/// (language may be overridden if the selected ecosystem doesn't support it)
struct EcosystemPromptResult {
    ecosystem: Ecosystem,
    language: Language,
}

async fn prompt_ecosystem(
    cli_init_flow: Option<InitFlow>,
    language: Language,
) -> Result<EcosystemPromptResult> {
    // If CLI args provide a specific init flow, use it directly
    if let Some(init_flow) = cli_init_flow {
        return handle_cli_init_flow(init_flow, &language).await;
    }

    // Otherwise, prompt for ecosystem selection
    let ecosystem_options = EcosystemOption::iter().collect();
    let ecosystem_option = Select::new("Choose blockchain ecosystem", ecosystem_options)
        .prompt()
        .context("Failed prompting for blockchain ecosystem")?;

    match ecosystem_option {
        EcosystemOption::Evm => {
            let ecosystem = prompt_evm_init_option(&language).await?;
            Ok(EcosystemPromptResult {
                ecosystem,
                language,
            })
        }
        EcosystemOption::Fuel => {
            let ecosystem = prompt_fuel_init_option(&language).await?;
            Ok(EcosystemPromptResult {
                ecosystem,
                language,
            })
        }
        EcosystemOption::Svm => prompt_svm_init_option(&language),
    }
}

/// Handle init flow provided via CLI arguments
async fn handle_cli_init_flow(
    init_flow: InitFlow,
    language: &Language,
) -> Result<EcosystemPromptResult> {
    match init_flow {
        InitFlow::Fuel {
            init_flow: maybe_init_flow,
        } => {
            let ecosystem = handle_fuel_cli_init_flow(maybe_init_flow, language).await?;
            Ok(EcosystemPromptResult {
                ecosystem,
                language: language.clone(),
            })
        }
        InitFlow::Template(args) => {
            let chosen_template = args.template.unwrap_or(evm::Template::Greeter);
            Ok(EcosystemPromptResult {
                ecosystem: Ecosystem::Evm {
                    init_flow: evm::InitFlow::Template(chosen_template),
                },
                language: language.clone(),
            })
        }
        InitFlow::SubgraphMigration(args) => {
            let input_subgraph_id = match args.subgraph_id {
                Some(id) => id,
                None => Text::new("[BETA VERSION] What is the subgraph ID?")
                    .prompt()
                    .context("Prompting user for subgraph id")?,
            };
            Ok(EcosystemPromptResult {
                ecosystem: Ecosystem::Evm {
                    init_flow: evm::InitFlow::SubgraphID(input_subgraph_id),
                },
                language: language.clone(),
            })
        }
        InitFlow::ContractImport(args) => Ok(EcosystemPromptResult {
            ecosystem: Ecosystem::Evm {
                init_flow: evm_prompts::prompt_contract_import_init_flow(args).await?,
            },
            language: language.clone(),
        }),
        InitFlow::Svm {
            init_flow: maybe_init_flow,
        } => handle_svm_cli_init_flow(maybe_init_flow, language),
    }
}

/// Handle Fuel CLI init flow
async fn handle_fuel_cli_init_flow(
    maybe_init_flow: Option<clap_definitions::fuel::InitFlow>,
    language: &Language,
) -> Result<Ecosystem> {
    match maybe_init_flow {
        Some(clap_definitions::fuel::InitFlow::Template(args)) => Ok(Ecosystem::Fuel {
            init_flow: fuel_prompts::prompt_template_init_flow(args)?,
        }),
        Some(clap_definitions::fuel::InitFlow::ContractImport(args)) => Ok(Ecosystem::Fuel {
            init_flow: fuel_prompts::prompt_contract_import_init_flow(args).await?,
        }),
        None => prompt_fuel_init_option(language).await,
    }
}

/// Handle SVM CLI init flow
fn handle_svm_cli_init_flow(
    maybe_init_flow: Option<clap_definitions::svm::InitFlow>,
    language: &Language,
) -> Result<EcosystemPromptResult> {
    // SVM only has template options which aren't available in ReScript
    let effective_language = if matches!(language, Language::ReScript) {
        println!(
            "Note: SVM templates are only available in TypeScript. Creating a TypeScript project."
        );
        Language::TypeScript
    } else {
        language.clone()
    };

    let ecosystem = match maybe_init_flow {
        Some(clap_definitions::svm::InitFlow::Template(args)) => Ecosystem::Svm {
            init_flow: svm_prompts::prompt_template_init_flow(args)?,
        },
        None => Ecosystem::Svm {
            init_flow: crate::init_config::svm::InitFlow::Template(
                crate::init_config::svm::Template::FeatureBlockHandler,
            ),
        },
    };

    Ok(EcosystemPromptResult {
        ecosystem,
        language: effective_language,
    })
}

/// Prompt for EVM initialization with flattened options
async fn prompt_evm_init_option(language: &Language) -> Result<Ecosystem> {
    let options = EvmInitOption::all_options(language);
    let selected = Select::new("Choose an initialization option", options)
        .prompt()
        .context("Failed prompting for EVM initialization option")?;

    match selected {
        EvmInitOption::ContractImportExplorer => Ok(Ecosystem::Evm {
            init_flow: evm_prompts::prompt_contract_import_init_flow(
                clap_definitions::evm::ContractImportArgs {
                    local_or_explorer: Some(clap_definitions::evm::LocalOrExplorerImport::Explorer(
                        clap_definitions::evm::ExplorerImportArgs::default(),
                    )),
                    ..Default::default()
                },
            )
            .await?,
        }),
        EvmInitOption::ContractImportLocal => Ok(Ecosystem::Evm {
            init_flow: evm_prompts::prompt_contract_import_init_flow(
                clap_definitions::evm::ContractImportArgs {
                    local_or_explorer: Some(clap_definitions::evm::LocalOrExplorerImport::Local(
                        clap_definitions::evm::LocalImportArgs::default(),
                    )),
                    ..Default::default()
                },
            )
            .await?,
        }),
        EvmInitOption::TemplateGreeter => Ok(Ecosystem::Evm {
            init_flow: evm::InitFlow::Template(evm::Template::Greeter),
        }),
        EvmInitOption::TemplateErc20 => Ok(Ecosystem::Evm {
            init_flow: evm::InitFlow::Template(evm::Template::Erc20),
        }),
        EvmInitOption::FeatureFactory => Ok(Ecosystem::Evm {
            init_flow: evm::InitFlow::Template(evm::Template::FeatureFactory),
        }),
    }
}

/// Prompt for Fuel initialization with flattened options
async fn prompt_fuel_init_option(language: &Language) -> Result<Ecosystem> {
    let options = FuelInitOption::all_options(language);
    let selected = Select::new("Choose an initialization option", options)
        .prompt()
        .context("Failed prompting for Fuel initialization option")?;

    match selected {
        FuelInitOption::ContractImportLocal => Ok(Ecosystem::Fuel {
            init_flow: fuel_prompts::prompt_contract_import_init_flow(
                clap_definitions::fuel::ContractImportArgs::default(),
            )
            .await?,
        }),
        FuelInitOption::TemplateGreeter => Ok(Ecosystem::Fuel {
            init_flow: fuel::InitFlow::Template(fuel::Template::Greeter),
        }),
    }
}

/// Prompt for SVM initialization
/// Since SVM currently only has one option (Block Handler template),
/// we skip the intermediate prompt and go directly to initialization
fn prompt_svm_init_option(language: &Language) -> Result<EcosystemPromptResult> {
    // SVM only has template options which aren't available in ReScript
    let effective_language = if matches!(language, Language::ReScript) {
        println!(
            "Note: SVM templates are only available in TypeScript. Creating a TypeScript project."
        );
        Language::TypeScript
    } else {
        language.clone()
    };

    // SVM currently only has one template option, so we use it directly
    // This avoids unnecessary prompting when there's only one choice
    Ok(EcosystemPromptResult {
        ecosystem: Ecosystem::Svm {
            init_flow: crate::init_config::svm::InitFlow::Template(
                crate::init_config::svm::Template::FeatureBlockHandler,
            ),
        },
        language: effective_language,
    })
}

#[derive(Debug, Clone, strum::Display, strum::EnumIter, strum::EnumString)]
enum ApiTokenInput {
    #[strum(serialize = "Create a new API token (Opens https://envio.dev/app/api-tokens)")]
    Create,
    #[strum(serialize = "Add an existing API token")]
    AddExisting,
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
        None => Language::TypeScript,
    };

    let EcosystemPromptResult {
        ecosystem,
        language,
    } = prompt_ecosystem(init_args.init_commands, language)
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
