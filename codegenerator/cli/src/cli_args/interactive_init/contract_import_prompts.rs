use super::{
    clap_definitions::{
        ContractImportArgs, ExplorerImportArgs, LocalImportArgs, LocalOrExplorerImport,
    },
    inquire_helpers::FilePathCompleter,
    validation::{
        contains_no_whitespace_validator, first_char_is_alphabet_validator, is_abi_file_validator,
        is_only_alpha_numeric_characters_validator, UniqueValueValidator,
    },
};
use crate::{
    clap_definitions::Language,
    cli_args::interactive_init::validation::filter_duplicate_events,
    config_parsing::{
        chain_helpers::{Network, NetworkWithExplorer, SupportedNetwork},
        contract_import::converters::{
            self, AutoConfigError, AutoConfigSelection, ContractImportNetworkSelection,
            ContractImportSelection,
        },
        human_config::{parse_contract_abi, ToHumanReadable},
    },
    utils::address_type::Address,
};
use anyhow::{anyhow, Context, Result};
use async_recursion::async_recursion;
use inquire::{CustomType, MultiSelect, Select, Text};
use std::{fmt::Display, path::PathBuf, str::FromStr};
use strum::IntoEnumIterator;
use strum_macros::EnumIter;

///Returns the prompter which can call .prompt() to action, or add validators/other
///properties
fn contract_address_prompter() -> CustomType<'static, Address> {
    CustomType::<Address>::new("What is the address of the contract?")
        .with_help_message("Use the proxy address if your abi is a proxy implementation")
        .with_error_message(
            "Please input a valid contract address (should be a hexadecimal starting with (0x))",
        )
}

///Immediately calls the prompter
fn contract_address_prompt() -> Result<Address> {
    contract_address_prompter()
        .prompt()
        .context("Prompting user for contract address")
}

///Used a wrapper to implement own Display (Display formats to a string of the
///human readable event signature)
struct DisplayEventWrapper(ethers::abi::Event);

impl Display for DisplayEventWrapper {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.0.to_human_readable())
    }
}

///Convert to and from ethers Event
impl From<ethers::abi::Event> for DisplayEventWrapper {
    fn from(value: ethers::abi::Event) -> Self {
        Self(value)
    }
}

///Convert to and from ethers Event
impl From<DisplayEventWrapper> for ethers::abi::Event {
    fn from(value: DisplayEventWrapper) -> Self {
        value.0
    }
}

///Takes a vec of Events and sets up a multi selecet prompt
///with all selected by default. Whatever is selected in the prompt
///is returned
fn prompt_for_event_selection(events: Vec<ethers::abi::Event>) -> Result<Vec<ethers::abi::Event>> {
    //Wrap events with Display wrapper
    let wrapped_events: Vec<_> = events
        .into_iter()
        .map(|event| DisplayEventWrapper::from(event))
        .collect();

    //Collect all the indexes of the vector in another vector which will be used
    //to preselect all events
    let all_indexes_of_events = wrapped_events
        .iter()
        .enumerate()
        .map(|(i, _)| i)
        .collect::<Vec<usize>>();

    //Prompt for selection with all events selected by default
    let selected_wrapped_events =
        MultiSelect::new("Which events would you like to index?", wrapped_events)
            .with_default(&all_indexes_of_events)
            .prompt()?;

    //Unwrap the selected events and return
    let selected_events = selected_wrapped_events
        .into_iter()
        .map(|w_event| w_event.into())
        .collect();

    Ok(selected_events)
}

///Represents the choice a user makes for adding values to
///their auto config selection
#[derive(strum_macros::Display, EnumIter, Default, PartialEq)]
enum AddNewContractOption {
    #[default]
    #[strum(serialize = "I'm finished")]
    Finished,
    #[strum(serialize = "Add a new address for same contract on same network")]
    AddAddress,
    #[strum(serialize = "Add a new network for same contract")]
    AddNetwork,
    #[strum(serialize = "Add a new contract (with a different ABI)")]
    AddContract,
}

impl ContractImportNetworkSelection {
    ///Recursively asks to add an address to ContractImportNetworkSelection
    fn prompt_add_contract_address_to_network_selection(
        self,
        current_contract_name: &str,
        //Used in the case where we want to preselect add address
        preselected_add_new_contract_option: Option<AddNewContractOption>,
    ) -> Result<(Self, AddNewContractOption)> {
        let selected_option = match preselected_add_new_contract_option {
            Some(preselected) => preselected,
            None => {
                let options = AddNewContractOption::iter().collect::<Vec<_>>();
                let help_message = format!(
                    "Current contract: {}, on network: {}",
                    current_contract_name, self.network
                );
                Select::new("Would you like to add another contract?", options)
                    .with_starting_cursor(0)
                    .with_help_message(&help_message)
                    .prompt()
                    .context("Failed prompting for add contract")?
            }
        };

        if selected_option == AddNewContractOption::AddAddress {
            let address = contract_address_prompter()
                .with_validator(UniqueValueValidator::new(self.addresses.clone()))
                .prompt()
                .context("Failed prompting user for new address")?;
            let updated_selection = self.add_address(address);

            updated_selection
                .prompt_add_contract_address_to_network_selection(current_contract_name, None)
        } else {
            Ok((self, selected_option))
        }
    }
}

impl ContractImportSelection {
    //Recursively asks to add networks with addresses to ContractImportNetworkSelection
    fn prompt_add_network_to_contract_import_selection(
        self,
        add_new_contract_option: AddNewContractOption,
    ) -> Result<(Self, AddNewContractOption)> {
        if add_new_contract_option == AddNewContractOption::AddNetwork {
            //In a new network case, no RPC url could be
            //derived from CLI flags
            const NO_RPC_URL: Option<String> = None;

            //Select a new network (not from the list of existing network ids already added)
            let selected_network = prompt_for_network_id(&NO_RPC_URL, self.get_network_ids())
                .context("Failed selecting network")?;

            //Instantiate a network_selection without any  contract addresses
            let network_selection =
                ContractImportNetworkSelection::new_without_addresses(selected_network);
            //Populate contract addresses with prompt
            let (network_selection, add_new_contract_option) = network_selection
                .prompt_add_contract_address_to_network_selection(
                    &self.name,
                    Some(AddNewContractOption::AddAddress),
                )
                .context("Failed adding new contract address")?;

            //Add the network to the contract selection
            let contract_selection = self.add_network(network_selection);

            //Reprompt to add more or exit
            contract_selection
                .prompt_add_network_to_contract_import_selection(add_new_contract_option)
        } else {
            //Exit if the user does not want to add more networks
            Ok((self, add_new_contract_option))
        }
    }
}

impl AutoConfigSelection {
    ///Recursively prompts to import a new contract or exits
    #[async_recursion]
    async fn prompt_for_add_contract_import_selection(
        self,
        add_new_contract_option: AddNewContractOption,
    ) -> Result<Self> {
        if add_new_contract_option == AddNewContractOption::AddContract {
            //Import a new contract
            let (contract_import_selection, add_new_contract_option) =
                ContractImportArgs::default()
                    .get_contract_import_selection()
                    .await
                    .context("Failed getting new contract import selection")?;

            //Add contract to AutoConfigSelection, method will handle duplicate names
            //and prompting for new names
            let auto_config_selection = self
                .add_contract_with_prompt(contract_import_selection)
                .context("Failed adding contract import selection to AutoConfigSelection")?;

            auto_config_selection
                .prompt_for_add_contract_import_selection(add_new_contract_option)
                .await
        } else {
            Ok(self)
        }
    }

    ///Calls add_contract but handles case where these is a name collision and prompts for a new
    ///name
    fn add_contract_with_prompt(
        self,
        contract_import_selection: ContractImportSelection,
    ) -> Result<Self> {
        self.add_contract(contract_import_selection).or_else(|e|
            match e {
                AutoConfigError::ContractNameExists(mut contract, auto_config_selection) => {
                    let prompt_text = format!("Contract with name {} already exists in your project. Please provide an alternative name: ", contract.name);
                    contract.name = Text::new(&prompt_text).prompt().context("Failed prompting for new Contract name")?;
                    auto_config_selection.add_contract_with_prompt(contract)
                }
            }
        )
    }
}

impl ContractImportArgs {
    ///Constructs AutoConfigSelection vial cli args and prompts
    pub async fn get_auto_config_selection(
        &self,
        project_name: String,
        language: Language,
    ) -> Result<AutoConfigSelection> {
        let (contract_import_selection, add_new_contract_option) = self
            .get_contract_import_selection()
            .await
            .context("Failed getting ContractImportSelection")?;

        let auto_config_selection =
            AutoConfigSelection::new(project_name, language, contract_import_selection);

        let auto_config_selection = if !self.single_contract {
            auto_config_selection
                .prompt_for_add_contract_import_selection(add_new_contract_option)
                .await
                .context("Failed adding contracts to AutoConfigSelection")?
        } else {
            auto_config_selection
        };

        Ok(auto_config_selection)
    }

    ///Constructs ContractImportSelection via cli args and prompts
    async fn get_contract_import_selection(
        &self,
    ) -> Result<(ContractImportSelection, AddNewContractOption)> {
        //Construct ContractImportSelection via explorer or local import
        let (contract_import_selection, add_new_contract_option) =
            match &self.get_local_or_explorer()? {
                LocalOrExplorerImport::Explorer(explorer_import_args) => self
                    .get_contract_import_selection_from_explore_import_args(explorer_import_args)
                    .await
                    .context("Failed getting ContractImportSelection from explorer")?,
                LocalOrExplorerImport::Local(local_import_args) => self
                    .get_contract_import_selection_from_local_import_args(local_import_args)
                    .await
                    .context("Failed getting ContractImportSelection from local")?,
            };

        //If --single-contract flag was not passed in, prompt to ask the user
        //if they would like to add networks to their contract selection
        let (contract_import_selection, add_new_contract_option) = if !self.single_contract {
            contract_import_selection
                .prompt_add_network_to_contract_import_selection(add_new_contract_option)
                .context("Failed adding networks to ContractImportSelection")?
        } else {
            (contract_import_selection, AddNewContractOption::Finished)
        };

        Ok((contract_import_selection, add_new_contract_option))
    }

    //Constructs ContractImportSelection via local prompt. Uses abis and manual
    //network/contract config
    async fn get_contract_import_selection_from_local_import_args(
        &self,
        local_import_args: &LocalImportArgs,
    ) -> Result<(ContractImportSelection, AddNewContractOption)> {
        let parsed_abi = local_import_args
            .get_parsed_abi()
            .context("Failed getting parsed abi")?;
        let mut abi_events: Vec<ethers::abi::Event> = parsed_abi.events().cloned().collect();

        if !self.all_events {
            abi_events =
                prompt_for_event_selection(abi_events).context("Failed selecting events")?;
        }

        let network = local_import_args
            .get_network()
            .context("Failed getting chosen network")?;

        let contract_name = local_import_args
            .get_contract_name()
            .context("Failed getting contract name")?;

        let address = self
            .get_contract_address()
            .context("Failed getting contract address")?;

        let network_selection = ContractImportNetworkSelection::new(network, address);

        //If the flag for --single-contract was not added, continue to prompt for adding
        //addresses to the given network for this contract
        let (network_selection, add_new_contract_option) = if !self.single_contract {
            network_selection
                .prompt_add_contract_address_to_network_selection(&contract_name, None)
                .context("Failed prompting for more contract addresses on network")?
        } else {
            (network_selection, AddNewContractOption::Finished)
        };

        let contract_selection =
            ContractImportSelection::new(contract_name, network_selection, abi_events);

        Ok((contract_selection, add_new_contract_option))
    }

    ///Constructs ContractImportSelection via block explorer requests.
    async fn get_contract_import_selection_from_explore_import_args(
        &self,
        explorer_import_args: &ExplorerImportArgs,
    ) -> Result<(ContractImportSelection, AddNewContractOption)> {
        let network_with_explorer = explorer_import_args
            .get_network_with_explorer()
            .context("Failed getting NetworkWithExporer")?;

        let chosen_contract_address = self
            .get_contract_address()
            .context("Failed getting contract address")?;

        let contract_selection_from_etherscan = ContractImportSelection::from_etherscan(
            &network_with_explorer,
            chosen_contract_address,
        )
        .await
        .context("Failed getting ContractImportSelection from explorer")?;

        let ContractImportSelection {
            name,
            networks,
            events,
        } = if !self.all_events {
            let events = prompt_for_event_selection(contract_selection_from_etherscan.events)
                .context("Failed selecting events")?;
            ContractImportSelection {
                events,
                ..contract_selection_from_etherscan
            }
        } else {
            contract_selection_from_etherscan
        };

        let last_network_selection = networks.last().cloned().ok_or_else(|| {
            anyhow!("Expected a network seletion to be constructed with ContractImportSelection")
        })?;

        //If the flag for --single-contract was not added, continue to prompt for adding
        //addresses to the given network for this contract
        let (network_selection, add_new_contract_option) = if !self.single_contract {
            last_network_selection
                .prompt_add_contract_address_to_network_selection(&name, None)
                .context("Failed prompting for more contract addresses on network")?
        } else {
            (last_network_selection, AddNewContractOption::Finished)
        };

        let contract_selection = ContractImportSelection::new(name, network_selection, events);

        Ok((contract_selection, add_new_contract_option))
    }

    ///Takes either the address passed in by cli flag or prompts
    ///for an address
    fn get_contract_address(&self) -> Result<Address> {
        match &self.contract_address {
            Some(c) => Ok(c.clone()),
            None => contract_address_prompt(),
        }
    }

    ///Takes either the "local" or "explorer" subcommand from the cli args
    ///or prompts for a choice from the user
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

///Prompts for a Supported network or for the user to enter an
///id, if it is unsupported it requires an RPC url. If the rpc is already
///known it can be passed in as the first arg. Otherwise this will be prompted.
///It also checks that the network does not belong to a given list of network ids
///To validate that a user is not double selecting a network id
fn prompt_for_network_id(
    opt_rpc_url: &Option<String>,
    already_selected_ids: Vec<u64>,
) -> Result<converters::Network> {
    //The first option of the list, funnels the user to enter a u64
    let enter_id = "<Enter Network Id>";

    //Select one of our supported networks
    let networks = SupportedNetwork::iter()
        //Don't allow selection of networks that have been previously
        //selected.
        .filter(|n| {
            let network_id = *n as u64;
            !already_selected_ids.contains(&network_id)
        })
        .map(|n| n.to_string())
        .collect::<Vec<_>>();

    //User's options to either enter an id or select a supported network
    let options = vec![vec![enter_id.to_string()], networks].concat();

    //Action prompt
    let choose_from_networks = Select::new("Choose network:", options)
        .prompt()
        .context("Failed during prompt for abi file path")?;

    let selected = match choose_from_networks.as_str() {
        //If the user's choice evaluates to the enter network id option, prompt them for
        //a network id
        choice if choice == enter_id => {
            let network_id = CustomType::<u64>::new("Enter the network id:")
                //Validate that this ID is not already selected
                .with_validator(UniqueValueValidator::new(already_selected_ids))
                .with_error_message("Invalid network id input, please enter a number")
                .prompt()?;

            //Convert the id into a supported or unsupported network.
            //If unsupported, it will use the optional rpc url or prompt
            //for an rpc url
            get_converter_network_u64(network_id, opt_rpc_url)?
        }
        //If a supported network choice was selected. We should be able to
        //parse it back to a supported network since it was serialized as a
        //string
        choice => converters::Network::Supported(
            SupportedNetwork::from_str(&choice)
                .context("Unexpected input, not a supported network.")?,
        ),
    };

    Ok(selected)
}

//Takes a u64 network ID and turns it into either "Supported" network or
//"Unsupported" where we need an RPC url. If the RPC url is known, pass it
//in as the 2nd arg otherwise prompt for an rpc url
fn get_converter_network_u64(
    network_id: u64,
    rpc_url: &Option<String>,
) -> Result<converters::Network> {
    let maybe_supported_network =
        Network::from_network_id(network_id).and_then(|n| Ok(SupportedNetwork::try_from(n)?));

    let network = match maybe_supported_network {
        Ok(s) => converters::Network::Supported(s),
        Err(_) => {
            let rpc_url = match rpc_url {
                Some(r) => r.clone(),
                None => prompt_for_rpc_url()?,
            };
            converters::Network::Unsupported(network_id, rpc_url)
        }
    };

    Ok(network)
}

///Prompt the user to enter an rpc url
fn prompt_for_rpc_url() -> Result<String> {
    Text::new(
        "You have entered a network that is unsupported by our servers. \
                        Please provide an rpc url (this can be edited later in config.yaml):",
    )
    .prompt()
    .context("Failed during rpc url prompt")
}

impl ExplorerImportArgs {
    ///Either take the NetworkWithExplorer value from the cli args or prompt
    ///for a user to select one.
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
    ///Internal function to get the abi path from the cli args or prompt for
    ///a file path to the abi
    fn get_abi_path_string(&self) -> Result<String> {
        match &self.abi_file {
            Some(p) => Ok(p.to_owned()),
            None => {
                let abi_path = Text::new("What is the path to your json abi file?")
                    //Auto completes path for user with tab/selection
                    .with_autocomplete(FilePathCompleter::default())
                    //Tries to parse the abi to ensure its valid and doesn't
                    //crash the prompt if not. Simply asks for a valid abi
                    .with_validator(is_abi_file_validator)
                    .prompt()
                    .context("Failed during prompt for abi file path")?;

                Ok(abi_path)
            }
        }
    }

    ///Get the file path for the abi and parse it into an abi
    fn get_parsed_abi(&self) -> Result<ethers::abi::Abi> {
        let abi_path_string = self.get_abi_path_string()?;

        let mut parsed_abi =
            parse_contract_abi(PathBuf::from(abi_path_string)).context("Failed to parse abi")?;

        parsed_abi.events = filter_duplicate_events(parsed_abi.events);

        Ok(parsed_abi)
    }

    ///Gets the network from from cli args or prompts for
    ///a network
    fn get_network(&self) -> Result<converters::Network> {
        match &self.blockchain {
            Some(b) => {
                let network_id: u64 = (b.clone()).into();
                get_converter_network_u64(network_id, &self.rpc_url)
            }
            None => prompt_for_network_id(&self.rpc_url, vec![]),
        }
    }

    ///Prompts for a contract name
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
