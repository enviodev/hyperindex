mod inquire_helpers;
pub mod validation;

use self::validation::{
    contains_no_whitespace_validator, first_char_is_alphabet_validator, is_abi_file_validator,
    is_directory_new_validator, is_not_empty_string_validator,
    is_only_alpha_numeric_characters_validator, is_valid_foldername_inquire_validator,
    UniqueAddressValidator,
};
use super::clap_definitions::{
    ContractImportArgs, ExplorerImportArgs, InitArgs, InitFlow, Language, LocalImportArgs,
    LocalOrExplorerImport, ProjectPaths, Template as InitTemplate,
};
use crate::{
    cli_args::interactive_init::validation::filter_duplicate_events,
    config_parsing::{
        chain_helpers::{Network, NetworkWithExplorer, SupportedNetwork},
        contract_import::converters::{
            self, AutoConfigSelection, ContractImportNetworkSelection, ContractImportSelection,
        },
        human_config::parse_contract_abi,
    },
    constants::project_paths::DEFAULT_PROJECT_ROOT_PATH,
    utils::address_type::Address,
};
use anyhow::{anyhow, Context, Result};
use async_recursion::async_recursion;
use inquire::{Confirm, CustomType, Select, Text};

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
    pub async fn get_contract_import_selection(&self) -> Result<ContractImportSelection> {
        match &self.get_local_or_explorer()? {
            LocalOrExplorerImport::Explorer(explorer_import_args) => {
                self.get_contract_import_selection_from_explore_import_args(explorer_import_args)
                    .await
            }
            LocalOrExplorerImport::Local(local_import_args) => {
                self.get_contract_import_selection_from_local_import_args(local_import_args)
                    .await
            }
        }
    }

    fn contract_address_prompter() -> CustomType<'static, Address> {
        CustomType::<Address>::new("What is the address of the contract? (Use the proxy address if your abi is a proxy implementation)")
                        .with_error_message("Please input a valid contract address (should be a hexadecimal starting with (0x))")
    }

    fn contract_address_prompt() -> Result<Address> {
        Self::contract_address_prompter()
            .prompt()
            .context("Prompting user for contract address")
    }

    fn prompt_add_contract_address_to_network_selection(
        network_selection: &mut ContractImportNetworkSelection,
        contract_name: &str,
    ) -> Result<()> {
        let question = format!(
            "Would you like to add another address for contract {} on network {}? (y/n)",
            contract_name, network_selection.network
        );

        if Confirm::new(&question).prompt()? {
            let address = Self::contract_address_prompter()
                .with_validator(UniqueAddressValidator::new(
                    network_selection.addresses.clone(),
                ))
                .prompt()
                .context("Failed prompting user for new address")?;
            network_selection.add_address(address);

            Self::prompt_add_contract_address_to_network_selection(network_selection, contract_name)
        } else {
            Ok(())
        }
    }

    async fn get_contract_import_selection_from_local_import_args(
        &self,
        local_import_args: &LocalImportArgs,
    ) -> Result<ContractImportSelection> {
        let parsed_abi = local_import_args
            .get_parsed_abi()
            .context("Failed getting parsed abi")?;

        let network = local_import_args
            .get_network()
            .context("Failed getting chosen network")?;

        let contract_name = local_import_args
            .get_contract_name()
            .context("Failed getting contract name")?;

        let address = self
            .get_contract_address()
            .context("Failed getting contract address")?;

        let mut network_selection = ContractImportNetworkSelection::new(network, address);

        if !self.single_contract {
            Self::prompt_add_contract_address_to_network_selection(
                &mut network_selection,
                &contract_name,
            )?;
        }

        let selection =
            ContractImportSelection::from_abi(network_selection, contract_name, parsed_abi);

        Ok(selection)
    }

    async fn get_contract_import_selection_from_explore_import_args(
        &self,
        explorer_import_args: &ExplorerImportArgs,
    ) -> Result<ContractImportSelection> {
        let network_with_explorer = explorer_import_args
            .get_network_with_explorer()
            .context("Failed getting NetworkWithExporer")?;

        let chosen_contract_address = self
            .get_contract_address()
            .context("Failed getting contract address")?;

        let mut contract_selection = ContractImportSelection::from_etherscan(
            &network_with_explorer,
            chosen_contract_address,
        )
        .await
        .context("Failed getting ContractImportSelection from explorer")?;

        let last_network_selection = contract_selection.networks.last_mut().ok_or_else(|| {
            anyhow!("Expected a network seletion to be constructed with ContractImportSelection")
        })?;

        if !self.single_contract {
            Self::prompt_add_contract_address_to_network_selection(
                last_network_selection,
                &contract_selection.name,
            )?;
        }

        Ok(contract_selection)
    }

    fn get_contract_address(&self) -> Result<Address> {
        match &self.contract_address {
            Some(c) => Ok(c.clone()),
            None => Self::contract_address_prompt(),
        }
    }

    fn get_local_or_explorer(&self) -> Result<LocalOrExplorerImport> {
        match &self.local_or_explorer {
            Some(v) => Ok(v.clone()),
            None => {
                let options = LocalOrExplorerImport::iter().collect();

                Select::new(
                    "Would you like to import from a block explorer or a local abi?",
                    options,
                )
                .prompt()
                .context("Failed prompting for import from block explorer or local abi")
            }
        }
    }
}

impl ExplorerImportArgs {
    fn get_network_with_explorer(&self) -> Result<NetworkWithExplorer> {
        let chosen_network = match &self.blockchain {
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
                    .collect();

                Select::new(
                    "Which blockchain would you like to import a contract from?",
                    options,
                )
                .prompt()?
            }
        };

        Ok(chosen_network)
    }
}

impl LocalImportArgs {
    fn get_abi_path_string(&self) -> Result<String> {
        match &self.abi_file {
            Some(p) => Ok(p.to_owned()),
            None => {
                let abi_path = Text::new("What is the path to your json abi file?")
                    .with_autocomplete(FilePathCompleter::default())
                    .with_validator(is_abi_file_validator)
                    .prompt()
                    .context("Failed during prompt for abi file path")?;

                Ok(abi_path)
            }
        }
    }

    fn get_parsed_abi(&self) -> Result<ethers::abi::Abi> {
        let abi_path_string = self.get_abi_path_string()?;

        let mut parsed_abi =
            parse_contract_abi(PathBuf::from(abi_path_string)).context("Failed to parse abi")?;

        parsed_abi.events = filter_duplicate_events(parsed_abi.events);

        Ok(parsed_abi)
    }

    fn get_rpc_url(&self) -> Result<String> {
        match &self.rpc_url {
            Some(r) => Ok(r.to_owned()),
            None => Text::new(
                "You have entered a network that is unsupported by our servers. \
                        Please provide an rpc url (this can be edited later in config.yaml):",
            )
            .prompt()
            .context("Failed during rpc url prompt"),
        }
    }

    fn get_converter_network_from_network_id_prompt(
        &self,
        network_id: u64,
    ) -> Result<converters::Network> {
        let maybe_supported_network =
            Network::from_network_id(network_id).and_then(|n| Ok(SupportedNetwork::try_from(n)?));

        let network = match maybe_supported_network {
            Ok(s) => converters::Network::Supported(s),
            Err(_) => {
                let rpc_url = self.get_rpc_url()?;
                converters::Network::Unsupported(network_id, rpc_url)
            }
        };

        Ok(network)
    }

    fn get_network(&self) -> Result<converters::Network> {
        match &self.blockchain {
            Some(b) => {
                let network_id: u64 = (b.clone()).into();
                self.get_converter_network_from_network_id_prompt(network_id)
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

                let selected = match choose_from_networks.as_str() {
                    choice if choice == enter_id => {
                        let network_id = CustomType::<u64>::new("Enter the network id:")
                            .with_error_message("Invalid network id input, please enter a number")
                            .prompt()?;

                        self.get_converter_network_from_network_id_prompt(network_id)?
                    }
                    choice => converters::Network::Supported(
                        SupportedNetwork::from_str(&choice)
                            .context("Unexpected input, not a supported network.")?,
                    ),
                };

                Ok(selected)
            }
        }
    }

    fn get_contract_name(&self) -> Result<String> {
        match &self.contract_name {
            Some(n) => Ok(n.clone()),
            None => Text::new("What is the name of this contract?")
                .with_validator(contains_no_whitespace_validator)
                .with_validator(is_only_alpha_numeric_characters_validator)
                .with_validator(first_char_is_alphabet_validator)
                .prompt()
                .context("Failed during contract name prompt"),
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
                    let contract_import_selection = args.get_contract_import_selection().await?;

                    let auto_config_selection = AutoConfigSelection::new(
                        project_name.clone(),
                        language.clone(),
                        contract_import_selection,
                    );
                    InitilizationTypeWithArgs::ContractImportWithArgs(auto_config_selection)
                }
            };

            Ok(initialization)
        }
        None => {
            //start prompt to ask the user which initialization option they want
            let user_response_options = InitFlow::iter().collect();

            let user_response =
                Select::new("Choose an initialization option", user_response_options).prompt()?;

            get_init_args(&Some(user_response), project_name, language).await
        }
    }
}
