mod evm_prompts;
mod fuel_prompts;
mod inquire_helpers;
mod prompt_helpers;
mod shared_prompts;
mod svm_prompts;
pub mod validation;
pub mod navigation;

use prompt_helpers::prompt_select_with_back;

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
use async_recursion::async_recursion;
use inquire::{Select, Text};
use std::str::FromStr;
use strum::{Display, EnumIter, IntoEnumIterator};
use validation::{
    contains_no_whitespace_validator, is_directory_new_validator,
    is_valid_foldername_inquire_validator,
};

#[derive(Clone, Debug, Display, PartialEq, EnumIter)]
pub enum EcosystemOption {
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

/// Main entry point for ecosystem selection.
/// Handles both CLI args and interactive prompts, applying language overrides as needed.
/// Stores ecosystem in builder.ecosystem.completed_ecosystem when done.
async fn prompt_ecosystem(
    cli_init_flow: Option<InitFlow>,
    language: Language,
    init_args: &InitArgs,
    project_paths: &ProjectPaths,
    builder: &mut navigation::InitConfigBuilder,
    stack: &mut navigation::PromptStack,
) -> Result<navigation::PromptResult<()>> {
    let ecosystem = match cli_init_flow {
        Some(init_flow) => {
            // CLI args - no back option needed
            get_ecosystem_from_cli(init_flow, &language).await?
        }
        None => {
            // Interactive prompt - check for Back
            match get_ecosystem_from_prompt(&language, init_args, project_paths, builder, stack).await? {
                navigation::PromptResult::Back => {
                    return Ok(navigation::PromptResult::Back);
                }
                navigation::PromptResult::Value(eco) => {
                    eco
                }
            }
        }
    };

    // Apply language override (e.g., SVM only supports TypeScript)
    let final_language = apply_language_override(&ecosystem, language);
    
    // Store ecosystem in builder (for CLI args case, it's not already stored)
    if builder.ecosystem.is_none() {
        builder.ecosystem = Some(navigation::EcosystemBuilder::new());
    }
    if let Some(eco_builder) = &mut builder.ecosystem {
        eco_builder.completed_ecosystem = Some(ecosystem);
    }
    
    // Update language in builder
    builder.language = Some(final_language);
    
    Ok(navigation::PromptResult::Value(()))
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
/// Note: This function can appear recursive because handle_back_action can navigate back to it,
/// but handle_back_action uses a loop, not recursion, so this is safe.
#[async_recursion]
async fn get_ecosystem_from_prompt(
    language: &Language,
    init_args: &InitArgs,
    project_paths: &ProjectPaths,
    builder: &mut navigation::InitConfigBuilder,
    stack: &mut navigation::PromptStack,
) -> Result<navigation::PromptResult<Ecosystem>> {
    // Push current step to stack at the beginning
    stack.push(navigation::PromptStackEntry {
        step_name: navigation::PromptSteps::EcosystemSelection,
    });

    let option = match prompt_select_with_back(
        "Choose blockchain ecosystem",
        EcosystemOption::iter().collect(),
        "Failed prompting for blockchain ecosystem",
    )? {
        navigation::PromptResult::Back => {
            // Esc pressed - handle back navigation (clears data and navigates)
            handle_back_action(init_args, project_paths, builder, stack).await?;
            return Ok(navigation::PromptResult::Back);
        }
        navigation::PromptResult::Value(opt) => opt,
    };
    
    // Create/initialize EcosystemBuilder and set ecosystem_type when ecosystem is selected
    // This happens right after selection, before any ecosystem-specific prompts
    if builder.ecosystem.is_none() {
        builder.ecosystem = Some(navigation::EcosystemBuilder::new());
    }
    if let Some(eco_builder) = &mut builder.ecosystem {
        eco_builder.ecosystem_type = Some(option.clone());
    }
    
    match option {
        EcosystemOption::Evm => {
            prompt_evm_init_option(language, init_args, project_paths, builder, stack).await?;
        }
        EcosystemOption::Fuel => {
            prompt_fuel_init_option(language, init_args, project_paths, builder, stack).await?;
        }
        // SVM only has one template option, skip the selection prompt
        EcosystemOption::Svm => {
            // Set completed ecosystem directly for SVM
            if let Some(eco_builder) = &mut builder.ecosystem {
                eco_builder.completed_ecosystem = Some(Ecosystem::Svm {
            init_flow: crate::init_config::svm::InitFlow::Template(
                crate::init_config::svm::Template::FeatureBlockHandler,
            ),
                });
            }
        }
    };

    // Check if ecosystem is complete in builder
    if let Some(eco_builder) = &builder.ecosystem {
        if let Some(completed_eco) = &eco_builder.completed_ecosystem {
            return Ok(navigation::PromptResult::Value(completed_eco.clone()));
        }
    }

    // If we get here, user went back (or something unexpected happened)
    Ok(navigation::PromptResult::Back)
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
        None => {
            // This path is for CLI args, not interactive prompts
            // So we don't have builder/stack - use a simple prompt
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
/// Sets state in builder and calls next function - doesn't return values
#[async_recursion]
async fn prompt_evm_init_option(
    language: &Language,
    init_args: &InitArgs,
    project_paths: &ProjectPaths,
    builder: &mut navigation::InitConfigBuilder,
    stack: &mut navigation::PromptStack,
) -> Result<()> {
    // Push current step to stack at the beginning
    stack.push(navigation::PromptStackEntry {
        step_name: navigation::PromptSteps::EvmInitOption,
    });

    let selected = match prompt_select_with_back(
        "Choose an initialization option",
        EvmInitOption::all_options(language),
        "Failed prompting for EVM initialization option",
    )? {
        navigation::PromptResult::Back => {
            // Esc pressed - handle back navigation (clears data and navigates)
            handle_back_action(init_args, project_paths, builder, stack).await?;
            return Ok(());
        }
        navigation::PromptResult::Value(opt) => opt,
    };

    let eco_builder = builder.ecosystem.get_or_insert_with(|| navigation::EcosystemBuilder::new());

    match selected {
        EvmInitOption::ContractImportExplorer => {
            // Initialize current_contract for EVM contract import (Explorer)
            eco_builder.current_contract = Some(navigation::ContractBuilder::new_evm());
            if let Some(navigation::ContractBuilder::Evm(evm_builder)) = &mut eco_builder.current_contract {
                evm_builder.import_type = Some(navigation::EvmImportType::Explorer);
            }
            
            // Call the contract import flow - it will set completed_ecosystem when done
            prompt_evm_contract_import_flow(init_args, project_paths, builder, stack).await?;
        }
        EvmInitOption::ContractImportLocal => {
            // Initialize current_contract for EVM contract import (Local)
            eco_builder.current_contract = Some(navigation::ContractBuilder::new_evm());
            if let Some(navigation::ContractBuilder::Evm(evm_builder)) = &mut eco_builder.current_contract {
                evm_builder.import_type = Some(navigation::EvmImportType::Local);
            }
            
            // Call the contract import flow - it will set completed_ecosystem when done
            prompt_evm_contract_import_flow(init_args, project_paths, builder, stack).await?;
        }
        EvmInitOption::TemplateErc20 => {
            let init_flow = evm::InitFlow::Template(evm::Template::Erc20);
            eco_builder.completed_ecosystem = Some(Ecosystem::Evm { init_flow });
        }
        EvmInitOption::TemplateGreeter => {
            let init_flow = evm::InitFlow::Template(evm::Template::Greeter);
            eco_builder.completed_ecosystem = Some(Ecosystem::Evm { init_flow });
        }
        EvmInitOption::FeatureFactory => {
            let init_flow = evm::InitFlow::Template(evm::Template::FeatureFactory);
            eco_builder.completed_ecosystem = Some(Ecosystem::Evm { init_flow });
        }
    }
    
    Ok(())
}

/// Prompt for Fuel initialization with flattened options
/// Sets state in builder and calls next function - doesn't return values
async fn prompt_fuel_init_option(
    language: &Language,
    init_args: &InitArgs,
    project_paths: &ProjectPaths,
    builder: &mut navigation::InitConfigBuilder,
    stack: &mut navigation::PromptStack,
) -> Result<()> {
    // Push current step to stack at the beginning
    stack.push(navigation::PromptStackEntry {
        step_name: navigation::PromptSteps::FuelInitOption,
    });

    let selected = match prompt_select_with_back(
        "Choose an initialization option",
        FuelInitOption::all_options(language),
        "Failed prompting for Fuel initialization option",
    )? {
        navigation::PromptResult::Back => {
            // Esc pressed - handle back navigation (clears data and navigates)
            handle_back_action(init_args, project_paths, builder, stack).await?;
            return Ok(());
        }
        navigation::PromptResult::Value(opt) => opt,
    };

    // Get or create ecosystem builder
    let eco_builder = builder.ecosystem.get_or_insert_with(|| navigation::EcosystemBuilder::new());

    match selected {
        FuelInitOption::ContractImportLocal => {
            // Initialize current_contract for Fuel contract import
            eco_builder.current_contract = Some(navigation::ContractBuilder::new_fuel());
            
            // Call the contract import flow - it will set completed_ecosystem when done
            prompt_fuel_contract_import_flow(init_args, project_paths, builder, stack).await?;
        }
        FuelInitOption::TemplateGreeter => {
            // Store template in builder
            eco_builder.template = Some(fuel::Template::Greeter);
            let init_flow = fuel::InitFlow::Template(fuel::Template::Greeter);
            // Store completed ecosystem in builder
            eco_builder.completed_ecosystem = Some(Ecosystem::Fuel { init_flow });
        }
    }

    Ok(())
}

/// Entry point for Fuel contract import flow
/// Starts the chain of prompts: ABI path → Network → Address → Name → Events → Add another?
/// Sets completed_ecosystem in builder when done
async fn prompt_fuel_contract_import_flow(
    init_args: &InitArgs,
    project_paths: &ProjectPaths,
    builder: &mut navigation::InitConfigBuilder,
    stack: &mut navigation::PromptStack,
) -> Result<()> {
    prompt_fuel_contract_abi_path(init_args, project_paths, builder, stack).await
}

/// Step 1: Prompt for ABI path
/// After success, calls prompt_fuel_contract_network
async fn prompt_fuel_contract_abi_path(
    init_args: &InitArgs,
    project_paths: &ProjectPaths,
    builder: &mut navigation::InitConfigBuilder,
    stack: &mut navigation::PromptStack,
) -> Result<()> {
    use std::path::PathBuf;
    use crate::fuel::abi::FuelAbi;
    use prompt_helpers::prompt_text_with_back;

    // Push step to stack
    stack.push(navigation::PromptStackEntry {
        step_name: navigation::PromptSteps::FuelContractAbiPath,
    });

    let eco_builder = builder.ecosystem.as_mut()
        .ok_or_else(|| anyhow::anyhow!("EcosystemBuilder not initialized"))?;

    let current_contract = match &mut eco_builder.current_contract {
        Some(navigation::ContractBuilder::Fuel(builder)) => builder,
        _ => return Err(anyhow::anyhow!("Current contract not initialized or wrong type")),
    };

    match prompt_text_with_back(
        "What is the path to your json abi file?",
        current_contract.abi_path.as_deref(),
    )? {
        navigation::PromptResult::Back => {
            handle_back_action(init_args, project_paths, builder, stack).await?;
            return Ok(());
        }
        navigation::PromptResult::Value(path) => {
            // Parse and validate ABI
            let abi = FuelAbi::parse(PathBuf::from(&path))
                .context("Failed parsing Fuel ABI")?;
            current_contract.abi_path = Some(path);
            current_contract.abi = Some(abi);
            
            // Continue to next step
            prompt_fuel_contract_network(init_args, project_paths, builder, stack).await
        }
    }
}

/// Step 2: Prompt for network
/// After success, calls prompt_fuel_contract_address
async fn prompt_fuel_contract_network(
    init_args: &InitArgs,
    project_paths: &ProjectPaths,
    builder: &mut navigation::InitConfigBuilder,
    stack: &mut navigation::PromptStack,
) -> Result<()> {
    use crate::init_config::fuel::Network;

    // Push step to stack
    stack.push(navigation::PromptStackEntry {
        step_name: navigation::PromptSteps::FuelContractNetwork,
    });

    let eco_builder = builder.ecosystem.as_mut()
        .ok_or_else(|| anyhow::anyhow!("EcosystemBuilder not initialized"))?;

    let current_contract = match &mut eco_builder.current_contract {
        Some(navigation::ContractBuilder::Fuel(builder)) => builder,
        _ => return Err(anyhow::anyhow!("Current contract not initialized or wrong type")),
    };

    match prompt_select_with_back(
        "Choose network:",
        vec![Network::Mainnet, Network::Testnet],
        "Failed during prompt for network",
    )? {
        navigation::PromptResult::Back => {
            handle_back_action(init_args, project_paths, builder, stack).await?;
            return Ok(());
        }
        navigation::PromptResult::Value(net) => {
            current_contract.network = Some(net);
            
            // Continue to next step
            prompt_fuel_contract_address(init_args, project_paths, builder, stack).await
        }
    }
}

/// Step 3: Prompt for address
/// After success, calls prompt_fuel_contract_name
async fn prompt_fuel_contract_address(
    init_args: &InitArgs,
    project_paths: &ProjectPaths,
    builder: &mut navigation::InitConfigBuilder,
    stack: &mut navigation::PromptStack,
) -> Result<()> {
    use crate::fuel::address::Address;
    use prompt_helpers::prompt_text_with_back;

    // Push step to stack
    stack.push(navigation::PromptStackEntry {
        step_name: navigation::PromptSteps::FuelContractAddress,
    });

    let eco_builder = builder.ecosystem.as_mut()
        .ok_or_else(|| anyhow::anyhow!("EcosystemBuilder not initialized"))?;

    let current_contract = match &mut eco_builder.current_contract {
        Some(navigation::ContractBuilder::Fuel(builder)) => builder,
        _ => return Err(anyhow::anyhow!("Current contract not initialized or wrong type")),
    };

    // Convert Address to string for default value
    let default_addr = current_contract.addresses.first().map(|a| format!("{}", a));

    match prompt_text_with_back(
        "What is the address of the contract?",
        default_addr.as_deref(),
    )? {
        navigation::PromptResult::Back => {
            handle_back_action(init_args, project_paths, builder, stack).await?;
            return Ok(());
        }
        navigation::PromptResult::Value(addr_str) => {
            let addr: Address = addr_str.parse()
                .context("Failed to parse address")?;
            if current_contract.addresses.is_empty() {
                current_contract.addresses.push(addr);
            } else {
                current_contract.addresses[0] = addr;
            }
            
            // Continue to next step
            prompt_fuel_contract_name(init_args, project_paths, builder, stack).await
        }
    }
}

/// Step 4: Prompt for contract name
/// After success, calls prompt_fuel_contract_events
async fn prompt_fuel_contract_name(
    init_args: &InitArgs,
    project_paths: &ProjectPaths,
    builder: &mut navigation::InitConfigBuilder,
    stack: &mut navigation::PromptStack,
) -> Result<()> {
    use crate::config_parsing::contract_import::converters::normalize_contract_name;
    use prompt_helpers::prompt_text_with_back;

    // Push step to stack
    stack.push(navigation::PromptStackEntry {
        step_name: navigation::PromptSteps::FuelContractName,
    });

    let eco_builder = builder.ecosystem.as_mut()
        .ok_or_else(|| anyhow::anyhow!("EcosystemBuilder not initialized"))?;

    let current_contract = match &mut eco_builder.current_contract {
        Some(navigation::ContractBuilder::Fuel(builder)) => builder,
        _ => return Err(anyhow::anyhow!("Current contract not initialized or wrong type")),
    };

    match prompt_text_with_back(
        "What is the name of this contract?",
        current_contract.name.as_deref(),
    )? {
        navigation::PromptResult::Back => {
            handle_back_action(init_args, project_paths, builder, stack).await?;
            return Ok(());
        }
        navigation::PromptResult::Value(n) => {
            current_contract.name = Some(normalize_contract_name(n));
            
            // Continue to next step
            prompt_fuel_contract_events(init_args, project_paths, builder, stack).await
        }
    }
}

/// Step 5: Prompt for events
/// After success, commits contract and calls prompt_fuel_add_another_contract
async fn prompt_fuel_contract_events(
    init_args: &InitArgs,
    project_paths: &ProjectPaths,
    builder: &mut navigation::InitConfigBuilder,
    stack: &mut navigation::PromptStack,
) -> Result<()> {
    use crate::config_parsing::human_config::fuel::EventConfig;
    use crate::fuel::abi::{TRANSFER_EVENT_NAME, MINT_EVENT_NAME, BURN_EVENT_NAME, CALL_EVENT_NAME};
    use prompt_helpers::prompt_multiselect_with_back;
    use shared_prompts::SelectItem;

    // Push step to stack
    stack.push(navigation::PromptStackEntry {
        step_name: navigation::PromptSteps::FuelContractEvents,
    });

    let eco_builder = builder.ecosystem.as_mut()
        .ok_or_else(|| anyhow::anyhow!("EcosystemBuilder not initialized"))?;

    let current_contract = match &mut eco_builder.current_contract {
        Some(navigation::ContractBuilder::Fuel(builder)) => builder,
        _ => return Err(anyhow::anyhow!("Current contract not initialized or wrong type")),
    };

    // Get events from ABI
    let mut selected_events: Vec<EventConfig> = current_contract.abi.as_ref().unwrap()
        .get_logs()
        .iter()
        .map(|log| EventConfig {
            name: log.event_name.clone(),
            log_id: Some(log.id.clone()),
            type_: None,
        })
        .collect();

    // Add standard events
    let event_names = [
        TRANSFER_EVENT_NAME,
        MINT_EVENT_NAME,
        BURN_EVENT_NAME,
        CALL_EVENT_NAME,
    ];
    selected_events.extend(event_names.iter().map(|&name| EventConfig {
        name: name.to_string(),
        log_id: None,
        type_: None,
    }));

    // Build SelectItem list and default indices
    let event_items: Vec<SelectItem<(usize, EventConfig)>> = selected_events.iter().enumerate().map(|(i, event)| SelectItem {
        display: event.name.clone(),
        preselect: event.log_id.is_some(),
        item: (i, event.clone()),
    }).collect();
    
    let default_indices: Vec<usize> = event_items.iter().enumerate()
        .filter_map(|(i, item)| if item.preselect { Some(i) } else { None })
        .collect();

    match prompt_multiselect_with_back(
        "Which events would you like to index?",
        event_items,
        Some(&default_indices),
        "Failed selecting ABI events",
    )? {
        navigation::PromptResult::Back => {
            handle_back_action(init_args, project_paths, builder, stack).await?;
            return Ok(());
        }
        navigation::PromptResult::Value(selected) => {
            let events: Vec<EventConfig> = selected.into_iter().map(|item| item.item.1).collect();
            current_contract.events = Some(events);
            
            // Contract is now complete, but don't commit yet - wait for "I'm finished" or "Add new contract"
            // Continue to "add another" prompt
            prompt_fuel_add_another_contract(init_args, project_paths, builder, stack).await
        }
    }
}

/// Step 6: Prompt for "add another contract" options
/// Handles the loop: Finished, AddAddress, AddNetwork, AddContract
/// Sets completed_ecosystem in builder when done
#[async_recursion]
async fn prompt_fuel_add_another_contract(
    init_args: &InitArgs,
    project_paths: &ProjectPaths,
    builder: &mut navigation::InitConfigBuilder,
    stack: &mut navigation::PromptStack,
) -> Result<()> {
    use shared_prompts::prompt_contract_address;
    use crate::fuel::address::Address;
    
    // Push step to stack
    stack.push(navigation::PromptStackEntry {
        step_name: navigation::PromptSteps::FuelAddAnotherContract,
    });

    let eco_builder = builder.ecosystem.as_mut()
        .ok_or_else(|| anyhow::anyhow!("EcosystemBuilder not initialized"))?;

    // Get current contract info for the prompt
    let (contract_name, network_name) = if let Some(navigation::ContractBuilder::Fuel(ref contract)) = eco_builder.current_contract {
        let name = contract.name.as_ref()
            .ok_or_else(|| anyhow::anyhow!("Contract name not set"))?;
        let network = contract.network.as_ref()
            .ok_or_else(|| anyhow::anyhow!("Network not set"))?;
        let network_str = match network {
            fuel::Network::Mainnet => "Fuel Mainnet",
            fuel::Network::Testnet => "Fuel Testnet",
        };
        (name.clone(), network_str.to_string())
    } else {
        return Err(anyhow::anyhow!("Current contract not found or wrong type"));
    };

    // Build options (Fuel doesn't support AddNetwork)
    let options = vec![
        AddNewContractOption::Finished,
        AddNewContractOption::AddAddress,
        AddNewContractOption::AddContract,
    ];

    let help_message = format!(
        "Current contract: {}, on network: {}",
        contract_name, network_name
    );

    // Use Select directly to add help message
    let selected = match Select::new("Would you like to add another contract?", options)
        .with_help_message(&help_message)
        .prompt_skippable()
        .context("Failed prompting for add contract option")?
    {
        Some(option) => option,
        None => {
            // Esc pressed - handle back
            handle_back_action(init_args, project_paths, builder, stack).await?;
            return Ok(());
        }
    };

    match selected {
        AddNewContractOption::Finished => {
            // Commit current_contract and finalize
            let completed_contract = if let Some(navigation::ContractBuilder::Fuel(builder)) = eco_builder.current_contract.take() {
                builder.to_selected_contract()?
            } else {
                return Err(anyhow::anyhow!("Current contract not found or wrong type"));
            };
            eco_builder.fuel_contracts.push(completed_contract);
            
            // Finalize ecosystem
            let contracts = eco_builder.fuel_contracts.clone();
            eco_builder.completed_ecosystem = Some(Ecosystem::Fuel {
                init_flow: fuel::InitFlow::ContractImport(
                    fuel::ContractImportSelection { contracts }
                )
            });
            Ok(())
        }
        AddNewContractOption::AddAddress => {
            // Edit current_contract to add another address
            if let Some(navigation::ContractBuilder::Fuel(ref mut contract)) = eco_builder.current_contract {
                let existing_addresses: Vec<String> = contract.addresses.iter()
                    .map(|a| format!("{}", a))
                    .collect();
                let new_address_str = prompt_contract_address(Some(&existing_addresses))?;
                let new_address = Address::from_str(&new_address_str)
                    .map_err(|e| anyhow::anyhow!("Invalid Fuel address: {}", e))?;
                contract.addresses.push(new_address);
            } else {
                return Err(anyhow::anyhow!("Current contract not found or wrong type"));
            }
            
            // Show prompt again
            prompt_fuel_add_another_contract(init_args, project_paths, builder, stack).await
        }
        AddNewContractOption::AddNetwork => {
            // Fuel doesn't support multiple networks
            return Err(anyhow::anyhow!("Fuel supports only one network at the moment"));
        }
        AddNewContractOption::AddContract => {
            // Commit current_contract, then start new contract flow
            let completed_contract = if let Some(navigation::ContractBuilder::Fuel(builder)) = eco_builder.current_contract.take() {
                builder.to_selected_contract()?
            } else {
                return Err(anyhow::anyhow!("Current contract not found or wrong type"));
            };
            eco_builder.fuel_contracts.push(completed_contract);
            
            // Start new contract flow
            eco_builder.current_contract = Some(navigation::ContractBuilder::new_fuel());
            prompt_fuel_contract_import_flow(init_args, project_paths, builder, stack).await
        }
    }
}

/// Helper enum for "add another contract" options
#[derive(Clone, Debug, strum::Display, strum::EnumIter, PartialEq)]
enum AddNewContractOption {
    #[strum(serialize = "I'm finished")]
    Finished,
    #[strum(serialize = "Add a new address for same contract on same network")]
    AddAddress,
    #[strum(serialize = "Add a new network for same contract")]
    AddNetwork,
    #[strum(serialize = "Add a new contract (with a different ABI)")]
    AddContract,
}

// ============================================================================
// EVM Contract Import Flow
// ============================================================================

/// Entry point for EVM contract import flow
/// Routes to Local or Explorer path based on import_type
/// Sets completed_ecosystem in builder when done
async fn prompt_evm_contract_import_flow(
    init_args: &InitArgs,
    project_paths: &ProjectPaths,
    builder: &mut navigation::InitConfigBuilder,
    stack: &mut navigation::PromptStack,
) -> Result<()> {
    let eco_builder = builder.ecosystem.as_mut()
        .ok_or_else(|| anyhow::anyhow!("EcosystemBuilder not initialized"))?;

    let current_contract = match &eco_builder.current_contract {
        Some(navigation::ContractBuilder::Evm(builder)) => builder,
        _ => return Err(anyhow::anyhow!("Current contract not initialized or wrong type")),
    };

    match current_contract.import_type.as_ref() {
        Some(navigation::EvmImportType::Local) => {
            prompt_evm_contract_abi_path(init_args, project_paths, builder, stack).await
        }
        Some(navigation::EvmImportType::Explorer) => {
            prompt_evm_contract_network(init_args, project_paths, builder, stack).await
        }
        None => Err(anyhow::anyhow!("Import type not set for EVM contract")),
    }
}

/// Step 1a (Local): Prompt for ABI path
/// After success, calls prompt_evm_contract_address
async fn prompt_evm_contract_abi_path(
    init_args: &InitArgs,
    project_paths: &ProjectPaths,
    builder: &mut navigation::InitConfigBuilder,
    stack: &mut navigation::PromptStack,
) -> Result<()> {
    use prompt_helpers::prompt_text_with_back;
    use crate::evm::abi::AbiOrNestedAbi;
    use serde_json;

    // Push step to stack
    stack.push(navigation::PromptStackEntry {
        step_name: navigation::PromptSteps::EvmContractAbiPath,
    });

    let eco_builder = builder.ecosystem.as_mut()
        .ok_or_else(|| anyhow::anyhow!("EcosystemBuilder not initialized"))?;

    let current_contract = match &mut eco_builder.current_contract {
        Some(navigation::ContractBuilder::Evm(builder)) => builder,
        _ => return Err(anyhow::anyhow!("Current contract not initialized or wrong type")),
    };

    match prompt_text_with_back(
        "What is the path to your json abi file?",
        current_contract.abi_path.as_deref(),
    )? {
        navigation::PromptResult::Back => {
            handle_back_action(init_args, project_paths, builder, stack).await?;
            return Ok(());
        }
        navigation::PromptResult::Value(path) => {
            // Parse and validate ABI (same logic as LocalImportArgs::parse_contract_abi)
            let abi_file = std::fs::read_to_string(&path)
                .context(format!("Failed to read ABI file at {}", path))?;
            let abi = match serde_json::from_str::<AbiOrNestedAbi>(&abi_file)
                .context(format!("Failed to deserialize ABI at {}", path))? {
                AbiOrNestedAbi::Abi(abi) => abi,
                AbiOrNestedAbi::NestedAbi { abi } => abi,
            };
            current_contract.abi_path = Some(path);
            current_contract.abi = Some(abi);
            
            // Continue to address step
            prompt_evm_contract_address(init_args, project_paths, builder, stack).await
        }
    }
}

/// Step 1b (Explorer): Prompt for network
/// After success, calls prompt_evm_contract_address
async fn prompt_evm_contract_network(
    init_args: &InitArgs,
    project_paths: &ProjectPaths,
    builder: &mut navigation::InitConfigBuilder,
    stack: &mut navigation::PromptStack,
) -> Result<()> {
    use crate::config_parsing::chain_helpers::{HypersyncNetwork, Network, NetworkWithExplorer};
    use crate::config_parsing::contract_import::converters::NetworkKind;
    use prompt_helpers::prompt_select_with_back;
    use strum::IntoEnumIterator;

    // Push step to stack
    stack.push(navigation::PromptStackEntry {
        step_name: navigation::PromptSteps::EvmContractNetwork,
    });

    let eco_builder = builder.ecosystem.as_mut()
        .ok_or_else(|| anyhow::anyhow!("EcosystemBuilder not initialized"))?;

    let current_contract = match &mut eco_builder.current_contract {
        Some(navigation::ContractBuilder::Evm(builder)) => builder,
        _ => return Err(anyhow::anyhow!("Current contract not initialized or wrong type")),
    };

    // Get network options
    let networks: Vec<NetworkWithExplorer> = NetworkWithExplorer::iter().collect();
    
    match prompt_select_with_back(
        "Choose blockchain network:",
        networks,
        "Failed prompting for network",
    )? {
        navigation::PromptResult::Back => {
            handle_back_action(init_args, project_paths, builder, stack).await?;
            return Ok(());
        }
        navigation::PromptResult::Value(network) => {
            // Convert NetworkWithExplorer to NetworkKind via HypersyncNetwork
            let network_enum = Network::from(network);
            let hypersync_network = HypersyncNetwork::try_from(network_enum)
                .context("Network is not supported by Hypersync")?;
            let network_kind = NetworkKind::Supported(hypersync_network);
            current_contract.network = Some(network_kind);
            
            // Continue to address step
            prompt_evm_contract_address(init_args, project_paths, builder, stack).await
        }
    }
}

/// Step 2: Prompt for contract address
/// After success, calls prompt_evm_contract_name
async fn prompt_evm_contract_address(
    init_args: &InitArgs,
    project_paths: &ProjectPaths,
    builder: &mut navigation::InitConfigBuilder,
    stack: &mut navigation::PromptStack,
) -> Result<()> {
    use crate::evm::address::Address;
    use prompt_helpers::prompt_text_with_back;

    // Push step to stack
    stack.push(navigation::PromptStackEntry {
        step_name: navigation::PromptSteps::EvmContractAddress,
    });

    let eco_builder = builder.ecosystem.as_mut()
        .ok_or_else(|| anyhow::anyhow!("EcosystemBuilder not initialized"))?;

    let current_contract = match &mut eco_builder.current_contract {
        Some(navigation::ContractBuilder::Evm(builder)) => builder,
        _ => return Err(anyhow::anyhow!("Current contract not initialized or wrong type")),
    };

    // Convert Address to string for default value
    let default_addr = current_contract.address.as_ref().map(|a| format!("{}", a));

    match prompt_text_with_back(
        "What is the address of the contract?",
        default_addr.as_deref(),
    )? {
        navigation::PromptResult::Back => {
            handle_back_action(init_args, project_paths, builder, stack).await?;
            return Ok(());
        }
        navigation::PromptResult::Value(addr_str) => {
            let addr: Address = addr_str.parse()
                .context("Failed to parse address")?;
            current_contract.address = Some(addr);
            
            // Continue to next step
            prompt_evm_contract_name(init_args, project_paths, builder, stack).await
        }
    }
}

/// Step 3: Prompt for contract name
/// After success, calls prompt_evm_contract_events
async fn prompt_evm_contract_name(
    init_args: &InitArgs,
    project_paths: &ProjectPaths,
    builder: &mut navigation::InitConfigBuilder,
    stack: &mut navigation::PromptStack,
) -> Result<()> {
    use crate::config_parsing::contract_import::converters::normalize_contract_name;
    use prompt_helpers::prompt_text_with_back;

    // Push step to stack
    stack.push(navigation::PromptStackEntry {
        step_name: navigation::PromptSteps::EvmContractName,
    });

    let eco_builder = builder.ecosystem.as_mut()
        .ok_or_else(|| anyhow::anyhow!("EcosystemBuilder not initialized"))?;

    let current_contract = match &mut eco_builder.current_contract {
        Some(navigation::ContractBuilder::Evm(builder)) => builder,
        _ => return Err(anyhow::anyhow!("Current contract not initialized or wrong type")),
    };

    match prompt_text_with_back(
        "What is the name of this contract?",
        current_contract.name.as_deref(),
    )? {
        navigation::PromptResult::Back => {
            handle_back_action(init_args, project_paths, builder, stack).await?;
            return Ok(());
        }
        navigation::PromptResult::Value(n) => {
            current_contract.name = Some(normalize_contract_name(n));
            
            // Continue to next step
            prompt_evm_contract_events(init_args, project_paths, builder, stack).await
        }
    }
}

/// Step 4: Prompt for events
/// After success, commits contract and calls prompt_evm_add_another_contract
async fn prompt_evm_contract_events(
    init_args: &InitArgs,
    project_paths: &ProjectPaths,
    builder: &mut navigation::InitConfigBuilder,
    stack: &mut navigation::PromptStack,
) -> Result<()> {
    use crate::config_parsing::system_config::EvmAbi;
    use prompt_helpers::prompt_multiselect_with_back;
    use shared_prompts::SelectItem;
    use alloy_json_abi::Event as AlloyEvent;

    // Push step to stack
    stack.push(navigation::PromptStackEntry {
        step_name: navigation::PromptSteps::EvmContractEvents,
    });

    let eco_builder = builder.ecosystem.as_mut()
        .ok_or_else(|| anyhow::anyhow!("EcosystemBuilder not initialized"))?;

    let current_contract = match &mut eco_builder.current_contract {
        Some(navigation::ContractBuilder::Evm(builder)) => builder,
        _ => return Err(anyhow::anyhow!("Current contract not initialized or wrong type")),
    };

    // Get events from ABI
    let events: Vec<AlloyEvent> = match &current_contract.abi {
        Some(abi) => abi.events().cloned().collect(),
        None => {
            // If Explorer path, we need to fetch ABI - for now, return error
            return Err(anyhow::anyhow!("ABI not available for event selection. Explorer import not fully implemented yet."));
        }
    };

    // Build SelectItem list
    let event_items: Vec<SelectItem<AlloyEvent>> = events.iter().map(|event| SelectItem {
        display: EvmAbi::event_signature_from_abi_event(event),
        preselect: true,
        item: event.clone(),
    }).collect();
    
    let default_indices: Vec<usize> = (0..event_items.len()).collect();

    match prompt_multiselect_with_back(
        "Which events would you like to index?",
        event_items,
        Some(&default_indices),
        "Failed selecting ABI events",
    )? {
        navigation::PromptResult::Back => {
            handle_back_action(init_args, project_paths, builder, stack).await?;
            return Ok(());
        }
        navigation::PromptResult::Value(selected) => {
            let events: Vec<AlloyEvent> = selected.into_iter().map(|item| item.item).collect();
            current_contract.events = Some(events);
            
            // Contract is now complete, but don't commit yet - wait for "I'm finished" or "Add new contract"
            // Continue to "add another" prompt
            prompt_evm_add_another_contract(init_args, project_paths, builder, stack).await
        }
    }
}

/// Step 5: Prompt for "add another contract" options
/// Handles the loop: Finished, AddAddress, AddNetwork, AddContract
/// Sets completed_ecosystem in builder when done
#[async_recursion]
async fn prompt_evm_add_another_contract(
    init_args: &InitArgs,
    project_paths: &ProjectPaths,
    builder: &mut navigation::InitConfigBuilder,
    stack: &mut navigation::PromptStack,
) -> Result<()> {
    use crate::config_parsing::contract_import::converters::ContractImportNetworkSelection;
    use crate::evm::address::Address as EvmAddress;
    use shared_prompts::prompt_contract_address;
    use evm_prompts::prompt_for_network_id;
    use inquire::Select;
    
    // Push step to stack
    stack.push(navigation::PromptStackEntry {
        step_name: navigation::PromptSteps::EvmAddAnotherContract,
    });

    let eco_builder = builder.ecosystem.as_mut()
        .ok_or_else(|| anyhow::anyhow!("EcosystemBuilder not initialized"))?;

    // Convert current_contract to SelectedContract to get info and enable editing
    let mut temp_contract = if let Some(navigation::ContractBuilder::Evm(builder)) = eco_builder.current_contract.take() {
        builder.to_selected_contract()?
    } else {
        return Err(anyhow::anyhow!("Current contract not found or wrong type"));
    };

    // Get contract info for the prompt
    let contract_name = temp_contract.name.clone();
    let network_name = temp_contract.get_last_chain_name()?;

    // Build options
    let options = vec![
        AddNewContractOption::Finished,
        AddNewContractOption::AddAddress,
        AddNewContractOption::AddNetwork,
        AddNewContractOption::AddContract,
    ];

    let help_message = format!(
        "Current contract: {}, on network: {}",
        contract_name, network_name
    );

    let selected = match Select::new("Would you like to add another contract?", options)
        .with_help_message(&help_message)
        .prompt_skippable()
        .context("Failed prompting for add contract option")?
    {
        Some(option) => option,
        None => {
            // Esc pressed - convert back to builder and handle back
            let contract_builder = navigation::EvmContractBuilder::from_selected_contract(&temp_contract)?;
            eco_builder.current_contract = Some(navigation::ContractBuilder::Evm(contract_builder));
            handle_back_action(init_args, project_paths, builder, stack).await?;
            return Ok(());
        }
    };

    match selected {
        AddNewContractOption::Finished => {
            // Commit and finalize
            eco_builder.evm_contracts.push(temp_contract);
            
            let contracts = eco_builder.evm_contracts.clone();
            eco_builder.completed_ecosystem = Some(Ecosystem::Evm {
                init_flow: evm::InitFlow::ContractImport(
                    evm::ContractImportSelection { selected_contracts: contracts }
                )
            });
            Ok(())
        }
        AddNewContractOption::AddAddress => {
            // Add address to last chain
            let chain = temp_contract.get_last_chain_mut()?;
            let existing_addresses: Vec<String> = chain.addresses.iter()
                .map(|a| format!("{}", a))
                .collect();
            let new_address_str = prompt_contract_address(Some(&existing_addresses))?;
            let new_address = EvmAddress::from_str(&new_address_str)
                .map_err(|e| anyhow::anyhow!("Invalid EVM address: {}", e))?;
            chain.addresses.push(new_address);
            
            // Convert back to builder and show prompt again
            let contract_builder = navigation::EvmContractBuilder::from_selected_contract(&temp_contract)?;
            eco_builder.current_contract = Some(navigation::ContractBuilder::Evm(contract_builder));
            prompt_evm_add_another_contract(init_args, project_paths, builder, stack).await
        }
        AddNewContractOption::AddNetwork => {
            // Add new network
            const NO_RPC_URL: Option<String> = None;
            const NO_START_BLOCK: Option<u64> = None;
            let selected_network = prompt_for_network_id(&NO_RPC_URL, &NO_START_BLOCK, temp_contract.get_chain_ids())
                .context("Failed selecting network")?;
            
            let network_selection = ContractImportNetworkSelection::new_without_addresses(selected_network);
            temp_contract.chains.push(network_selection);
            
            // Prompt for address on new network
            let chain = temp_contract.get_last_chain_mut()?;
            let existing_addresses: Vec<String> = chain.addresses.iter()
                .map(|a| format!("{}", a))
                .collect();
            let new_address_str = prompt_contract_address(Some(&existing_addresses))?;
            let new_address = EvmAddress::from_str(&new_address_str)
                .map_err(|e| anyhow::anyhow!("Invalid EVM address: {}", e))?;
            chain.addresses.push(new_address);
            
            // Convert back to builder and show prompt again
            let contract_builder = navigation::EvmContractBuilder::from_selected_contract(&temp_contract)?;
            eco_builder.current_contract = Some(navigation::ContractBuilder::Evm(contract_builder));
            prompt_evm_add_another_contract(init_args, project_paths, builder, stack).await
        }
        AddNewContractOption::AddContract => {
            // Commit current, then start new contract flow
            eco_builder.evm_contracts.push(temp_contract);
            
            // Start new contract flow
            eco_builder.current_contract = Some(navigation::ContractBuilder::new_evm());
            prompt_evm_contract_import_flow(init_args, project_paths, builder, stack).await
        }
    }
}

#[derive(Debug, Clone, strum::Display, strum::EnumIter, strum::EnumString)]
enum ApiTokenInput {
    #[strum(serialize = "Create a new API token (Opens https://envio.dev/app/api-tokens)")]
    Create,
    #[strum(serialize = "Add an existing API token")]
    AddExisting,
}






/// Prompt folder name (always the first step, no back navigation needed)
pub async fn prompt_folder_name(
    init_args: &InitArgs,
    project_paths: &ProjectPaths,
    builder: &mut navigation::InitConfigBuilder,
    stack: &mut navigation::PromptStack,
) -> Result<(String, String)> {
    let directory: String = match &project_paths.directory {
        Some(args_directory) => args_directory.clone(),
        None => {
            // Use current value as default if available
            let default = builder.directory.as_deref().unwrap_or(DEFAULT_PROJECT_ROOT_PATH);
            Text::new("Specify a folder name (ENTER to skip): ")
                .with_default(default)
                .with_validator(is_valid_foldername_inquire_validator)
                .with_validator(is_directory_new_validator)
                .with_validator(contains_no_whitespace_validator)
                .prompt()?
        }
    };

    let name: String = match &init_args.name {
        Some(args_name) => args_name.clone(),
        None => {
            if directory == DEFAULT_PROJECT_ROOT_PATH {
                "envio-indexer".to_string()
            } else {
                directory.to_string()
            }
        }
    };

    // Store in builder and push to stack
    builder.directory = Some(directory.clone());
    builder.name = Some(name.clone());
    
    // Push to stack (only if not already there)
    if stack.entries.last().map(|e| e.step_name.clone()) != Some(navigation::PromptSteps::FolderName) {
        stack.push(navigation::PromptStackEntry {
            step_name: navigation::PromptSteps::FolderName,
        });
    }

    Ok((name, directory))
}

/// Original function (kept for compatibility)
/// Set language (no actual prompt - uses CLI arg or default)
/// Not added to stack since it's automatic and has no prompt
pub async fn prompt_language(
    init_args: &InitArgs,
    builder: &mut navigation::InitConfigBuilder,
    _stack: &mut navigation::PromptStack,
) -> Result<()> {
    let language = init_args.language.clone().unwrap_or(Language::TypeScript);
    
    // Store in builder (but don't add to stack since there isn't actually a prompt here)
    builder.language = Some(language.clone());

    Ok(())
}

/// Navigate to a specific prompt step by matching on the step enum
/// This is the central dispatch function that maps PromptSteps to their prompt functions
pub async fn navigate_to_step(
    step: &navigation::PromptSteps,
    init_args: &InitArgs,
    project_paths: &ProjectPaths,
    builder: &mut navigation::InitConfigBuilder,
    stack: &mut navigation::PromptStack,
) -> Result<navigation::PromptResult<()>> {
    match step {
        navigation::PromptSteps::FolderName => {
            // Folder name is always first, no back navigation
            // prompt_folder_name already stores in builder and pushes to stack
            prompt_folder_name(init_args, project_paths, builder, stack).await?;
            Ok(navigation::PromptResult::Value(()))
        }
        navigation::PromptSteps::EcosystemSelection => {
            // Going back to ecosystem selection - clear all contract data
            if let Some(eco_builder) = &mut builder.ecosystem {
                eco_builder.clear_contracts();
            }
            // Re-prompt for ecosystem selection
            let language = builder.language.clone()
                .ok_or_else(|| anyhow::anyhow!("Language not set in builder"))?;
            match get_ecosystem_from_prompt(&language, init_args, project_paths, builder, stack).await? {
                navigation::PromptResult::Back => Ok(navigation::PromptResult::Back),
                navigation::PromptResult::Value(_) => Ok(navigation::PromptResult::Value(())),
            }
        }
        navigation::PromptSteps::EvmInitOption => {
            // Going back to EVM init option - clear current_contract if it exists
            if let Some(eco_builder) = &mut builder.ecosystem {
                eco_builder.current_contract = None;
                eco_builder.completed_ecosystem = None; // Clear any previous completion
            }
            // Re-prompt for EVM init option
            let language = builder.language.clone()
                .ok_or_else(|| anyhow::anyhow!("Language not set in builder"))?;
            prompt_evm_init_option(&language, init_args, project_paths, builder, stack).await?;
            Ok(navigation::PromptResult::Value(()))
        }
        navigation::PromptSteps::FuelInitOption => {
            // Going back to Fuel init option - clear current_contract if it exists
            if let Some(eco_builder) = &mut builder.ecosystem {
                eco_builder.current_contract = None;
                eco_builder.completed_ecosystem = None; // Clear any previous completion
            }
            // Re-prompt for Fuel init option
            let language = builder.language.clone()
                .ok_or_else(|| anyhow::anyhow!("Language not set in builder"))?;
            prompt_fuel_init_option(&language, init_args, project_paths, builder, stack).await?;
            Ok(navigation::PromptResult::Value(()))
        }
        navigation::PromptSteps::FuelContractAbiPath => {
            prompt_fuel_contract_abi_path(init_args, project_paths, builder, stack).await?;
            Ok(navigation::PromptResult::Value(()))
        }
        navigation::PromptSteps::FuelContractNetwork => {
            prompt_fuel_contract_network(init_args, project_paths, builder, stack).await?;
            Ok(navigation::PromptResult::Value(()))
        }
        navigation::PromptSteps::FuelContractAddress => {
            prompt_fuel_contract_address(init_args, project_paths, builder, stack).await?;
            Ok(navigation::PromptResult::Value(()))
        }
        navigation::PromptSteps::FuelContractName => {
            prompt_fuel_contract_name(init_args, project_paths, builder, stack).await?;
            Ok(navigation::PromptResult::Value(()))
        }
        navigation::PromptSteps::FuelContractEvents => {
            prompt_fuel_contract_events(init_args, project_paths, builder, stack).await?;
            Ok(navigation::PromptResult::Value(()))
        }
        navigation::PromptSteps::FuelAddAnotherContract => {
            prompt_fuel_add_another_contract(init_args, project_paths, builder, stack).await?;
            Ok(navigation::PromptResult::Value(()))
        }
        navigation::PromptSteps::EvmContractAbiPath => {
            prompt_evm_contract_abi_path(init_args, project_paths, builder, stack).await?;
            Ok(navigation::PromptResult::Value(()))
        }
        navigation::PromptSteps::EvmContractNetwork => {
            prompt_evm_contract_network(init_args, project_paths, builder, stack).await?;
            Ok(navigation::PromptResult::Value(()))
        }
        navigation::PromptSteps::EvmContractAddress => {
            prompt_evm_contract_address(init_args, project_paths, builder, stack).await?;
            Ok(navigation::PromptResult::Value(()))
        }
        navigation::PromptSteps::EvmContractName => {
            prompt_evm_contract_name(init_args, project_paths, builder, stack).await?;
            Ok(navigation::PromptResult::Value(()))
        }
        navigation::PromptSteps::EvmContractEvents => {
            prompt_evm_contract_events(init_args, project_paths, builder, stack).await?;
            Ok(navigation::PromptResult::Value(()))
        }
        navigation::PromptSteps::EvmAddAnotherContract => {
            // If we're going back to this step after "Add new contract", 
            // we need to pop the last contract and set it back to current_contract
            let eco_builder = builder.ecosystem.as_mut()
                .ok_or_else(|| anyhow::anyhow!("EcosystemBuilder not initialized"))?;
            
            // Check if we have completed contracts and no current_contract
            // This means we went back after "Add new contract"
            if eco_builder.current_contract.is_none() && !eco_builder.evm_contracts.is_empty() {
                if let Some(popped_contract) = eco_builder.evm_contracts.pop() {
                    // Convert SelectedContract back to ContractBuilder
                    let contract_builder = navigation::EvmContractBuilder::from_selected_contract(&popped_contract)?;
                    eco_builder.current_contract = Some(navigation::ContractBuilder::Evm(contract_builder));
                }
            }
            
            prompt_evm_add_another_contract(init_args, project_paths, builder, stack).await?;
            Ok(navigation::PromptResult::Value(()))
        }
        navigation::PromptSteps::ApiTokenOption => {
            let ecosystem = builder.ecosystem.as_ref()
                .and_then(|eco| eco.completed_ecosystem.as_ref())
                .ok_or_else(|| anyhow::anyhow!("Ecosystem not set in builder"))?
                .clone();
            let _token = prompt_api_token_option(init_args, project_paths, &ecosystem, builder, stack).await?;
            Ok(navigation::PromptResult::Value(()))
        }
        navigation::PromptSteps::ApiTokenInput => {
            let token = prompt_api_token_input(init_args, project_paths, builder, stack).await?;
            if let Some(t) = token {
                builder.api_token = Some(t);
            }
            Ok(navigation::PromptResult::Value(()))
        }
    }
}

/// Handle back navigation: clears data for current step, pops stack, navigates to previous step
/// Returns Ok(()) after navigation is complete
/// The current step is at the top of the stack (pushed at the beginning of the prompt)
/// The previous step is second from top
#[async_recursion]
pub async fn handle_back_action(
    init_args: &InitArgs,
    project_paths: &ProjectPaths,
    builder: &mut navigation::InitConfigBuilder,
    stack: &mut navigation::PromptStack,
) -> Result<()> {
    // Pop the current step from stack (the step we're leaving)
    let current_entry = stack.pop()
        .ok_or_else(|| anyhow::anyhow!("Cannot go back: no current step on stack"))?;
    
    // Clear data associated with the current step we're leaving
    match current_entry.step_name {
        navigation::PromptSteps::FolderName => {
            // Folder name is always first, shouldn't be going back from here
            // But if we do, clear it
            builder.name = None;
            builder.directory = None;
        }
        navigation::PromptSteps::EcosystemSelection => {
            // Clear entire ecosystem builder (ecosystem_type, templates, contracts, etc.)
            builder.ecosystem = None;
        }
        navigation::PromptSteps::EvmInitOption | navigation::PromptSteps::FuelInitOption => {
            // Clear template and current_contract, but keep ecosystem_type
            if let Some(eco_builder) = &mut builder.ecosystem {
                eco_builder.template = None;
                eco_builder.current_contract = None;
            }
        }
        navigation::PromptSteps::FuelContractAbiPath => {
            // Clear ABI path and ABI
            if let Some(eco_builder) = &mut builder.ecosystem {
                if let Some(navigation::ContractBuilder::Fuel(contract)) = &mut eco_builder.current_contract {
                    contract.abi_path = None;
                    contract.abi = None;
                }
            }
        }
        navigation::PromptSteps::FuelContractNetwork => {
            // Clear network
            if let Some(eco_builder) = &mut builder.ecosystem {
                if let Some(navigation::ContractBuilder::Fuel(contract)) = &mut eco_builder.current_contract {
                    contract.network = None;
                }
            }
        }
        navigation::PromptSteps::FuelContractAddress => {
            // Clear addresses
            if let Some(eco_builder) = &mut builder.ecosystem {
                if let Some(navigation::ContractBuilder::Fuel(contract)) = &mut eco_builder.current_contract {
                    contract.addresses.clear();
                }
            }
        }
        navigation::PromptSteps::FuelContractName => {
            // Clear name
            if let Some(eco_builder) = &mut builder.ecosystem {
                if let Some(navigation::ContractBuilder::Fuel(contract)) = &mut eco_builder.current_contract {
                    contract.name = None;
                }
            }
        }
        navigation::PromptSteps::FuelContractEvents => {
            // Clear events
            if let Some(eco_builder) = &mut builder.ecosystem {
                if let Some(navigation::ContractBuilder::Fuel(contract)) = &mut eco_builder.current_contract {
                    contract.events = None;
                }
            }
        }
        navigation::PromptSteps::FuelAddAnotherContract => {
            // No data to clear - this is just a navigation prompt
            // If we're going back from here, we might need to handle uncommitted current_contract
            // but that's handled in navigate_to_step
        }
        navigation::PromptSteps::EvmContractAbiPath => {
            // Clear ABI path and ABI
            if let Some(eco_builder) = &mut builder.ecosystem {
                if let Some(navigation::ContractBuilder::Evm(contract)) = &mut eco_builder.current_contract {
                    contract.abi_path = None;
                    contract.abi = None;
                }
            }
        }
        navigation::PromptSteps::EvmContractNetwork => {
            // Clear network
            if let Some(eco_builder) = &mut builder.ecosystem {
                if let Some(navigation::ContractBuilder::Evm(contract)) = &mut eco_builder.current_contract {
                    contract.network = None;
                }
            }
        }
        navigation::PromptSteps::EvmContractAddress => {
            // Clear address
            if let Some(eco_builder) = &mut builder.ecosystem {
                if let Some(navigation::ContractBuilder::Evm(contract)) = &mut eco_builder.current_contract {
                    contract.address = None;
                }
            }
        }
        navigation::PromptSteps::EvmContractName => {
            // Clear name
            if let Some(eco_builder) = &mut builder.ecosystem {
                if let Some(navigation::ContractBuilder::Evm(contract)) = &mut eco_builder.current_contract {
                    contract.name = None;
                }
            }
        }
        navigation::PromptSteps::EvmContractEvents => {
            // Clear events
            if let Some(eco_builder) = &mut builder.ecosystem {
                if let Some(navigation::ContractBuilder::Evm(contract)) = &mut eco_builder.current_contract {
                    contract.events = None;
                }
            }
        }
        navigation::PromptSteps::ApiTokenOption => {
            // Clear API token (going back from option selection)
            builder.api_token = None;
        }
        navigation::PromptSteps::ApiTokenInput => {
            // Clear API token (going back from token input)
            builder.api_token = None;
        }
        navigation::PromptSteps::FuelAddAnotherContract | navigation::PromptSteps::EvmAddAnotherContract => {
            // No data to clear - this is just a navigation prompt
            // If we're going back from here, we might need to handle uncommitted current_contract
            // but that's handled in navigate_to_step
        }
    }

    // Pop the previous step from stack (the step we're going back to)
    let previous_entry = stack.pop()
        .ok_or_else(|| anyhow::anyhow!("Cannot go back: no previous step"))?;

    // Navigate to the previous step
    // Use a loop instead of recursion to avoid boxing requirement
    let mut current_step = previous_entry.step_name;
    loop {
        let result = navigate_to_step(&current_step, init_args, project_paths, builder, stack).await?;
        
        match result {
            navigation::PromptResult::Value(_) => {
                break Ok(());
            }
            navigation::PromptResult::Back => {
                // User wants to go back again - pop and continue loop
                let prev_entry = stack.pop()
                    .ok_or_else(|| anyhow::anyhow!("Cannot go back: no previous step"))?;
                current_step = prev_entry.step_name;
            }
        }
    }
}




pub async fn prompt_missing_init_args(
    init_args: InitArgs,
    project_paths: &ProjectPaths,
) -> Result<InitConfig> {
    // Create builder and stack for new navigation system
    let mut builder = navigation::InitConfigBuilder::new();
    let mut stack = navigation::PromptStack::new();

    // Prompt for folder name and language using new system
    prompt_folder_name(&init_args, project_paths, &mut builder, &mut stack).await?;
    prompt_language(&init_args, &mut builder, &mut stack).await?;

    // Get language from builder for ecosystem selection
    let language = builder.language.clone()
        .ok_or_else(|| anyhow::anyhow!("Language not set in builder"))?;

    // Use existing ecosystem selection logic with Back support
    loop {
        match prompt_ecosystem(
            init_args.init_commands.clone(),
            language.clone(),
            &init_args,
            project_paths,
            &mut builder,
            &mut stack,
        )
        .await
        .context("Failed getting template")?
        {
            navigation::PromptResult::Back => {
                // User went back - handle_back_action was already called
                // Continue loop to re-prompt
                continue;
            }
            navigation::PromptResult::Value(_) => {
                // Ecosystem is now stored in builder.ecosystem.completed_ecosystem
                break;
            }
        }
    }

    // Get ecosystem from builder
    let ecosystem = builder.ecosystem.as_ref()
        .and_then(|eco| eco.completed_ecosystem.as_ref())
        .ok_or_else(|| anyhow::anyhow!("Ecosystem not set in builder"))?
        .clone();

    // Apply language override (e.g., SVM only supports TypeScript)
    let final_language = apply_language_override(&ecosystem, language);
    builder.language = Some(final_language.clone());

    // Prompt for API token with back handling
    prompt_api_token(&init_args, project_paths, &ecosystem, &mut builder, &mut stack).await?;

    // Build InitConfig from builder
    Ok(InitConfig {
        name: builder.name.clone()
            .ok_or_else(|| anyhow::anyhow!("Name not set in builder"))?,
        directory: builder.directory.clone()
            .ok_or_else(|| anyhow::anyhow!("Directory not set in builder"))?,
        ecosystem,
        language: final_language,
        api_token: builder.api_token.clone(),
    })
}

/// Prompt for API token with back navigation support
#[async_recursion]
async fn prompt_api_token(
    init_args: &InitArgs,
    project_paths: &ProjectPaths,
    ecosystem: &Ecosystem,
    builder: &mut navigation::InitConfigBuilder,
    stack: &mut navigation::PromptStack,
) -> Result<()> {
    let api_token: Option<String> = match &init_args.api_token {
        Some(k) => Some(k.clone()),
        None if ecosystem.uses_hypersync() => {
            // First prompt: "Create" or "Add existing"
            prompt_api_token_option(init_args, project_paths, ecosystem, builder, stack).await?
        }
        None => None,
    };

    // Store in builder
    builder.api_token = api_token;
    Ok(())
}

/// Step 1: Prompt for API token option ("Create" or "Add existing")
async fn prompt_api_token_option(
    init_args: &InitArgs,
    project_paths: &ProjectPaths,
    _ecosystem: &Ecosystem,
    builder: &mut navigation::InitConfigBuilder,
    stack: &mut navigation::PromptStack,
) -> Result<Option<String>> {
    use prompt_helpers::prompt_select_with_back;

    // Push step to stack
    stack.push(navigation::PromptStackEntry {
        step_name: navigation::PromptSteps::ApiTokenOption,
    });

    let select = match prompt_select_with_back(
                "Add an API token for HyperSync to your .env file?",
                ApiTokenInput::iter().collect(),
        "Failed prompting for API token option",
    )? {
        navigation::PromptResult::Back => {
            handle_back_action(init_args, project_paths, builder, stack).await?;
            return Ok(None);
        }
        navigation::PromptResult::Value(option) => option,
    };

            match select {
                ApiTokenInput::Create => {
                    open::that_detached("https://envio.dev/app/api-tokens")?;
            prompt_api_token_input(init_args, project_paths, builder, stack).await
        }
        ApiTokenInput::AddExisting => {
            prompt_api_token_input(init_args, project_paths, builder, stack).await
        }
    }
}

/// Step 2: Prompt for actual API token text input
async fn prompt_api_token_input(
    init_args: &InitArgs,
    project_paths: &ProjectPaths,
    builder: &mut navigation::InitConfigBuilder,
    stack: &mut navigation::PromptStack,
) -> Result<Option<String>> {
    use prompt_helpers::prompt_text_with_back;

    // Push step to stack
    stack.push(navigation::PromptStackEntry {
        step_name: navigation::PromptSteps::ApiTokenInput,
    });

    match prompt_text_with_back(
        "Add your API token:",
        builder.api_token.as_deref(),
    )? {
        navigation::PromptResult::Back => {
            handle_back_action(init_args, project_paths, builder, stack).await?;
            return Ok(None);
        }
        navigation::PromptResult::Value(token) => Ok(Some(token)),
    }
}

