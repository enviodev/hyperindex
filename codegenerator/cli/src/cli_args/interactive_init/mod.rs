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

/// Main entry point for ecosystem selection.
/// Handles both CLI args and interactive prompts, applying language overrides as needed.
async fn prompt_ecosystem(
    cli_init_flow: Option<InitFlow>,
    language: Language,
) -> Result<EcosystemPromptResult> {
    let ecosystem = match cli_init_flow {
        Some(init_flow) => get_ecosystem_from_cli(init_flow, &language).await?,
        None => get_ecosystem_from_prompt(&language).await?,
    };

    // Apply language override (e.g., SVM only supports TypeScript)
    let language = apply_language_override(&ecosystem, language);

    Ok(EcosystemPromptResult {
        ecosystem,
        language,
    })
}

/// Override language if the ecosystem doesn't support it
fn apply_language_override(ecosystem: &Ecosystem, language: Language) -> Language {
    if matches!(ecosystem, Ecosystem::Svm { .. }) && matches!(language, Language::ReScript) {
        println!(
            "Note: SVM templates are only available in TypeScript. Creating a TypeScript project."
        );
        Language::TypeScript
    } else {
        language
    }
}

/// Get ecosystem from CLI arguments
async fn get_ecosystem_from_cli(init_flow: InitFlow, language: &Language) -> Result<Ecosystem> {
    match init_flow {
        InitFlow::Fuel { init_flow } => get_fuel_ecosystem(init_flow, language).await,
        InitFlow::Svm { init_flow } => get_svm_ecosystem(init_flow),
        InitFlow::Template(args) => Ok(Ecosystem::Evm {
            init_flow: evm::InitFlow::Template(args.template.unwrap_or(evm::Template::Greeter)),
        }),
        InitFlow::SubgraphMigration(args) => {
            let subgraph_id = match args.subgraph_id {
                Some(id) => id,
                None => Text::new("[BETA VERSION] What is the subgraph ID?")
                    .prompt()
                    .context("Prompting user for subgraph id")?,
            };
            Ok(Ecosystem::Evm {
                init_flow: evm::InitFlow::SubgraphID(subgraph_id),
            })
        }
        InitFlow::ContractImport(args) => Ok(Ecosystem::Evm {
            init_flow: evm_prompts::prompt_contract_import_init_flow(args).await?,
        }),
    }
}

/// Get ecosystem from interactive prompts
async fn get_ecosystem_from_prompt(language: &Language) -> Result<Ecosystem> {
    let ecosystem_option = Select::new(
        "Choose blockchain ecosystem",
        EcosystemOption::iter().collect(),
    )
    .prompt()
    .context("Failed prompting for blockchain ecosystem")?;

    match ecosystem_option {
        EcosystemOption::Evm => prompt_evm_init_option(language).await,
        EcosystemOption::Fuel => prompt_fuel_init_option(language).await,
        // SVM only has one template option, skip the selection prompt
        EcosystemOption::Svm => Ok(Ecosystem::Svm {
            init_flow: crate::init_config::svm::InitFlow::Template(
                crate::init_config::svm::Template::FeatureBlockHandler,
            ),
        }),
    }
}

/// Get Fuel ecosystem from CLI args or prompt
async fn get_fuel_ecosystem(
    init_flow: Option<clap_definitions::fuel::InitFlow>,
    language: &Language,
) -> Result<Ecosystem> {
    match init_flow {
        Some(clap_definitions::fuel::InitFlow::Template(args)) => Ok(Ecosystem::Fuel {
            init_flow: fuel_prompts::prompt_template_init_flow(args)?,
        }),
        Some(clap_definitions::fuel::InitFlow::ContractImport(args)) => Ok(Ecosystem::Fuel {
            init_flow: fuel_prompts::prompt_contract_import_init_flow(args).await?,
        }),
        None => prompt_fuel_init_option(language).await,
    }
}

/// Get SVM ecosystem from CLI args (SVM only has template options)
fn get_svm_ecosystem(init_flow: Option<clap_definitions::svm::InitFlow>) -> Result<Ecosystem> {
    Ok(match init_flow {
        Some(clap_definitions::svm::InitFlow::Template(args)) => Ecosystem::Svm {
            init_flow: svm_prompts::prompt_template_init_flow(args)?,
        },
        None => Ecosystem::Svm {
            init_flow: crate::init_config::svm::InitFlow::Template(
                crate::init_config::svm::Template::FeatureBlockHandler,
            ),
        },
    })
}

/// Prompt for EVM initialization with flattened options
async fn prompt_evm_init_option(language: &Language) -> Result<Ecosystem> {
    let selected = Select::new(
        "Choose an initialization option",
        EvmInitOption::all_options(language),
    )
    .prompt()
    .context("Failed prompting for EVM initialization option")?;

    let init_flow = match selected {
        EvmInitOption::ContractImportExplorer => {
            evm_prompts::prompt_contract_import_init_flow(clap_definitions::evm::ContractImportArgs {
                local_or_explorer: Some(clap_definitions::evm::LocalOrExplorerImport::Explorer(
                    clap_definitions::evm::ExplorerImportArgs::default(),
                )),
                ..Default::default()
            })
            .await?
        }
        EvmInitOption::ContractImportLocal => {
            evm_prompts::prompt_contract_import_init_flow(clap_definitions::evm::ContractImportArgs {
                local_or_explorer: Some(clap_definitions::evm::LocalOrExplorerImport::Local(
                    clap_definitions::evm::LocalImportArgs::default(),
                )),
                ..Default::default()
            })
            .await?
        }
        EvmInitOption::TemplateErc20 => evm::InitFlow::Template(evm::Template::Erc20),
        EvmInitOption::TemplateGreeter => evm::InitFlow::Template(evm::Template::Greeter),
        EvmInitOption::FeatureFactory => evm::InitFlow::Template(evm::Template::FeatureFactory),
    };

    Ok(Ecosystem::Evm { init_flow })
}

/// Prompt for Fuel initialization with flattened options
async fn prompt_fuel_init_option(language: &Language) -> Result<Ecosystem> {
    let selected = Select::new(
        "Choose an initialization option",
        FuelInitOption::all_options(language),
    )
    .prompt()
    .context("Failed prompting for Fuel initialization option")?;

    let init_flow = match selected {
        FuelInitOption::ContractImportLocal => {
            fuel_prompts::prompt_contract_import_init_flow(
                clap_definitions::fuel::ContractImportArgs::default(),
            )
            .await?
        }
        FuelInitOption::TemplateGreeter => fuel::InitFlow::Template(fuel::Template::Greeter),
    };

    Ok(Ecosystem::Fuel { init_flow })
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
                .with_validator(is_valid_foldername_inquire_validator)
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

    let language = init_args.language.unwrap_or(Language::TypeScript);

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
        package_manager: init_args.package_manager,
    })
}
