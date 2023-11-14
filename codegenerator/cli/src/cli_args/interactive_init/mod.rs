mod inquire_helpers;
mod validation;

use self::validation::{is_directory_new_validator, is_valid_foldername_inquire_validator};

use super::clap_definitions::{
    ContractImportArgs, ExplorerImportArgs, InitArgs, InitFlow, Language, LocalImportArgs,
    LocalOrExplorerImport, ProjectPaths, Template as InitTemplate,
};
use crate::{
    config_parsing::{
        chain_helpers::{Network, NetworkWithExplorer, SupportedNetwork},
        contract_import::converters::{self, AutoConfigSelection},
        human_config::parse_contract_abi,
    },
    constants::project_paths::DEFAULT_PROJECT_ROOT_PATH,
    utils::address_type::Address,
};
use anyhow::{Context, Result};
use async_recursion::async_recursion;
use inquire::{Select, Text};
use inquire_helpers::FilePathCompleter;
use std::{path::PathBuf, str::FromStr};
use strum::IntoEnumIterator;

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

impl ContractImportArgs {
    fn get_converter_network_from_network_id_prompt(
        network_id: u64,
        rpc_url: Option<String>,
    ) -> Result<converters::Network> {
        let maybe_supported_network =
            Network::from_network_id(network_id).and_then(|n| Ok(SupportedNetwork::try_from(n)?));

        let network = match maybe_supported_network {
            Ok(s) => converters::Network::Supported(s),
            Err(_) => {
                let rpc_url = match rpc_url {
                    Some(r) => r,
                    None => Text::new(
                        "You have entered a network that is unsupported by our servers. \
                        Please provide an rpc url (this can be edited later in config.yaml):",
                    )
                    .prompt()
                    .context("Failed during rpc url prompt")?,
                };
                converters::Network::Unsupported(network_id, rpc_url)
            }
        };

        Ok(network)
    }

    pub async fn get_auto_config_selection(
        &self,
        project_name: String,
        language: Language,
    ) -> Result<AutoConfigSelection> {
        let local_or_explorer = match &self.local_or_explorer {
            Some(v) => v.clone(),
            None => {
                let options = LocalOrExplorerImport::iter()
                    .map(|choice| choice.to_string())
                    .collect::<Vec<String>>();

                let input_network = Select::new(
                    "Would you like to import from a block explorer or a local abi?",
                    options,
                )
                .prompt()
                .context("Failed prompting for import from block explorer or local abi")?;

                LocalOrExplorerImport::from_str(&input_network)
                    .context("Parsing local or explorer choice from string")?
            }
        };

        let get_chosen_contract_address = || -> Result<Address> {
            match &self.contract_address {
                Some(c) => Ok(c.clone()),
                None => {
                    let address_str = Text::new("What is the address of the contract? (Use the proxy address if your abi is a proxy implementation)")
                        .prompt()
                        .context("Prompting user for contract address")?;

                    parse_or_reprompt(
                        address_str,
                        |s| s.as_str().parse(),
                        "Invalid contract address input, please try again",
                    )
                }
            }
        };

        match local_or_explorer {
            LocalOrExplorerImport::Explorer(ExplorerImportArgs { blockchain }) => {
                let chosen_blockchain = match &blockchain {
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
                AutoConfigSelection::from_etherscan(
                    project_name,
                    language,
                    &chosen_blockchain,
                    get_chosen_contract_address()?,
                )
                .await
            }
            LocalOrExplorerImport::Local(LocalImportArgs {
                blockchain,
                abi_file,
                contract_name,
                rpc_url,
            }) => {
                let parse_and_reprompt_abi_path = |path: String| -> Result<_> {
                    parse_or_reprompt(
                        path,
                        |s| parse_contract_abi(PathBuf::from(s)),
                        "Invalid abi file path input, please try again",
                    )
                };

                let abi_path_string = match abi_file {
                    Some(p) => p,
                    None => {
                        let abi_path = Text::new("What is the path to your json abi file?")
                            .with_autocomplete(FilePathCompleter::default())
                            .prompt()
                            .context("Failed during prompt for abi file path")?;

                        abi_path
                    }
                };

                let parsed_abi = parse_and_reprompt_abi_path(abi_path_string)?;

                let network: converters::Network = match blockchain {
                    Some(b) => {
                        let network_id: u64 = b.into();
                        Self::get_converter_network_from_network_id_prompt(network_id, rpc_url)?
                    }
                    None => {
                        let enter_id = "<Enter Network Id>";
                        let networks = SupportedNetwork::iter()
                            .map(|n| n.to_string())
                            .collect::<Vec<_>>();

                        let options = vec![vec![enter_id.to_string()], networks].concat();

                        let choose_from_networks = Select::new("Choose network:", options)
                            .prompt()
                            .context("Failed during prompt for abi file path")?;

                        match choose_from_networks.as_str() {
                            choice if choice == enter_id => {
                                let id_string = Text::new("Enter the network id:").prompt()?;

                                let network_id: u64 = parse_or_reprompt(
                                    id_string,
                                    |s| Ok(s.as_str().parse()?),
                                    "Invalid network id input, please enter a number",
                                )?;

                                Self::get_converter_network_from_network_id_prompt(
                                    network_id, rpc_url,
                                )?
                            }
                            choice => converters::Network::Supported(
                                SupportedNetwork::from_str(&choice)
                                    .context("Unexpected input, not a supported network.")?,
                            ),
                        }
                    }
                };

                let contract_name = match contract_name {
                    Some(n) => n,
                    None => Text::new("What is the name of this contract?")
                        .prompt()
                        .context("Failed during contract name prompt")?,
                };

                let address = get_chosen_contract_address()?;

                Ok(AutoConfigSelection::from_abi(
                    project_name,
                    language,
                    network,
                    address,
                    contract_name,
                    parsed_abi,
                ))
            }
        }
    }
}

impl InitArgs {
    pub async fn get_init_args_interactive(
        &self,
        project_paths: &ProjectPaths,
    ) -> Result<InitInteractive> {
        let name: String = match &self.name {
            Some(args_name) => args_name.clone(),
            None => {
                // todo input validation for name
                Text::new("Name your indexer:").prompt()?
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

        let template: InitilizationTypeWithArgs =
            get_init_args(&self.init_commands, &name, &language).await?;

        Ok(InitInteractive {
            name,
            directory,
            template,
            language,
        })
    }
}

fn parse_or_reprompt<T>(
    val: String,
    parse_fn: fn(String) -> Result<T>,
    reprompt_msg: &str,
) -> Result<T> {
    let mut string = val;

    loop {
        match parse_fn(string) {
            Ok(parsed_val) => break Ok(parsed_val),
            Err(_) => {
                string = Text::new(reprompt_msg)
                    .prompt()
                    .context(format!("Failed during reprompt: {}", reprompt_msg))?;
            }
        }
    }
}

#[async_recursion]
async fn get_init_args(
    opt_init_flow: &Option<InitFlow>,
    project_name: &String,
    language: &Language,
) -> Result<InitilizationTypeWithArgs> {
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
                    InitilizationTypeWithArgs::ContractImportWithArgs(
                        args.get_auto_config_selection(project_name.clone(), language.clone())
                            .await?,
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

            get_init_args(&Some(chosen_init_option), project_name, language).await
        }
    }
}
