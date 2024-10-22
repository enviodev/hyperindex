use super::{
    clap_definitions::evm::{
        ContractImportArgs, ExplorerImportArgs, LocalImportArgs, LocalOrExplorerImport,
    },
    shared_prompts::{
        prompt_abi_file_path, prompt_contract_address, prompt_contract_name,
        prompt_events_selection, prompt_to_continue_adding, Contract, SelectItem,
    },
    validation::UniqueValueValidator,
};
use crate::{
    cli_args::interactive_init::validation::filter_duplicate_events,
    config_parsing::{
        chain_helpers::{self, HypersyncNetwork, Network, NetworkWithExplorer},
        contract_import::converters::{
            self, ContractImportNetworkSelection, NetworkKind, SelectedContract,
        },
        contract_import::{contract_import, ContractImportResult},
        system_config::EvmAbi,
    },
    evm::address::Address,
    init_config::evm::{ContractImportSelection, InitFlow},
};
use anyhow::{anyhow, Context, Result};
use inquire::{validator::Validation, CustomType, Select, Text};
use std::{env, path::PathBuf, str::FromStr};
use strum::IntoEnumIterator;

fn prompt_abi_events_selection(events: Vec<ethers::abi::Event>) -> Result<Vec<ethers::abi::Event>> {
    prompt_events_selection(
        events
            .into_iter()
            .map(|abi_event| SelectItem {
                display: EvmAbi::event_signature_from_abi_event(&abi_event),
                item: abi_event,
            })
            .collect(),
    )
    .context("Failed selecting ABI events")
}

impl ContractImportArgs {
    //Constructs SelectedContract via local prompt. Uses abis and manual
    //network/contract config
    async fn get_contract_import_selection_from_local_import_args(
        &self,
        local_import_args: &LocalImportArgs,
    ) -> Result<SelectedContract> {
        let parsed_abi = local_import_args
            .get_abi()
            .context("Failed getting parsed abi")?;
        let mut abi_events: Vec<ethers::abi::Event> = parsed_abi.events().cloned().collect();

        if !self.all_events {
            abi_events = prompt_abi_events_selection(abi_events)?;
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

        Ok(SelectedContract::new(
            contract_name,
            network_selection,
            abi_events,
        ))
    }

    async fn get_selected_contract(
        &self,
        network: &NetworkWithExplorer,
        contract_address: Address,
    ) -> anyhow::Result<SelectedContract> {
        let result = match contract_import(network, &contract_address, 0).await {
            Ok(ContractImportResult::Contract(contract_data)) => Ok(contract_data),
            Ok(ContractImportResult::NotVerified) => {
                println!("Failed to find the verified contract on a block explorer.");
                Err(())
            }
            Ok(ContractImportResult::UnsupportedChain) => {
                println!("The \"{network}\" chain doesn't support contract import yet. Let us know if you want it by opening an issue on Github.");
                Err(())
            }
            Err(e) => {
                println!(
                    "Failed getting the contract ABI with the following error:\n{}",
                    e
                );
                Err(())
            }
        };
        let contract_data = match result {
            Ok(contract_data) => contract_data,
            Err(_) => {
                println!("\nUse the Local ABI import option instead.");
                return self
                    .get_contract_import_selection_from_local_import_args(
                        &LocalImportArgs::default(),
                    )
                    .await;
            }
        };

        let network_kind = match chain_helpers::Network::from(network.clone()).try_into() {
            Ok(network) => NetworkKind::Supported(network),
            Err(_) => NetworkKind::Unsupported(network.clone() as u64, prompt_for_rpc_url()?),
        };

        let network_selection = ContractImportNetworkSelection::new(network_kind, contract_address);

        Ok(SelectedContract::new(
            contract_data.name,
            network_selection,
            contract_data.abi.events().cloned().collect(),
        ))
    }

    ///Constructs SelectedContract via block explorer requests.
    async fn get_contract_import_selection_from_explore_import_args(
        &self,
        explorer_import_args: &ExplorerImportArgs,
    ) -> Result<SelectedContract> {
        let network_with_explorer: NetworkWithExplorer = explorer_import_args
            .get_network_with_explorer()
            .context("Failed getting NetworkWithExporer")?;

        let chosen_contract_address = self
            .get_contract_address()
            .context("Failed getting contract address")?;

        let selected_contract = self
            .get_selected_contract(&network_with_explorer, chosen_contract_address)
            .await
            .context("Failed getting SelectedContract from explorer")?; // FIXME: Don't throw here

        let SelectedContract {
            name,
            networks,
            events,
        } = if !self.all_events {
            let events = prompt_abi_events_selection(selected_contract.events)?;
            SelectedContract {
                events,
                ..selected_contract
            }
        } else {
            selected_contract
        };

        let network_selection = networks.last().cloned().ok_or_else(|| {
            anyhow!("Expected a network seletion to be constructed with SelectedContract")
        })?;

        Ok(SelectedContract::new(name, network_selection, events))
    }

    ///Takes either the address passed in by cli flag or prompts
    ///for an address
    fn get_contract_address(&self) -> Result<Address> {
        match &self.contract_address {
            Some(c) => Ok(c.clone()),
            None => prompt_contract_address(None),
        }
    }

    ///Takes either the "local" or "explorer" subcommand from the cli args
    ///or prompts for a choice from the user
    fn get_local_or_explorer_import(&self) -> Result<LocalOrExplorerImport> {
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
    opt_start_block: &Option<u64>,
    already_selected_ids: Vec<u64>,
) -> Result<converters::NetworkKind> {
    //The first option of the list, funnels the user to enter a u64
    let enter_id = "<Enter Network Id>";

    //Select one of our supported networks
    let networks = HypersyncNetwork::iter()
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
            get_converter_network_u64(network_id, opt_rpc_url, opt_start_block)?
        }
        //If a supported network choice was selected. We should be able to
        //parse it back to a supported network since it was serialized as a
        //string
        choice => converters::NetworkKind::Supported(
            HypersyncNetwork::from_str(&choice)
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
    start_block: &Option<u64>,
) -> Result<converters::NetworkKind> {
    let maybe_supported_network =
        Network::from_network_id(network_id).and_then(|n| Ok(HypersyncNetwork::try_from(n)?));

    let network = match maybe_supported_network {
        Ok(s) => converters::NetworkKind::Supported(s),
        Err(_) => {
            let rpc_url = match rpc_url {
                Some(r) => r.clone(),
                None => prompt_for_rpc_url()?,
            };
            let start_block = match start_block {
                Some(s) => s.clone(),
                None => prompt_for_start_block()?,
            };

            converters::NetworkKind::Unsupported {
                network_id,
                rpc_url,
                start_block,
            }
        }
    };

    Ok(network)
}

///Prompt the user to enter a starting block
///only prompt when used when using rpc as it could
///be very slow to have the startblock at 0 with rpc 🦶🔫
fn prompt_for_start_block() -> Result<u64> {
    let start_block = CustomType::<u64>::new(
        "Please provide a start block for this network \
            (this can be edited later in config.yaml):",
    )
    .with_error_message("Invalid start block input, please enter a number 0 or greater")
    .prompt()?;

    Ok(start_block)
}

///Prompt the user to enter an rpc url
fn prompt_for_rpc_url() -> Result<String> {
    Text::new(
        "You have entered a network that is unsupported by our servers. Please provide an rpc url \
         (this can be edited later in config.yaml):",
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
                        HypersyncNetwork::iter()
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
    fn parse_contract_abi(abi_path: PathBuf) -> anyhow::Result<ethers::abi::Contract> {
        let abi_file = std::fs::read_to_string(&abi_path).context(format!(
            "Failed to read abi file at {:?}, relative to the current directory {:?}",
            abi_path,
            env::current_dir().unwrap_or(PathBuf::default())
        ))?;

        let abi: ethers::abi::Contract = serde_json::from_str(&abi_file).context(format!(
            "Failed to deserialize ABI at {:?} -  Please ensure the ABI file is formatted \
             correctly or contact the team.",
            abi_path
        ))?;

        Ok(abi)
    }

    ///Internal function to get the abi path from the cli args or prompt for
    ///a file path to the abi
    fn get_abi_path_string(&self) -> Result<String> {
        match &self.abi_file {
            Some(p) => Ok(p.clone()),
            None => prompt_abi_file_path(|path| {
                let maybe_parsed_abi = Self::parse_contract_abi(PathBuf::from(path));
                match maybe_parsed_abi {
                    Ok(_) => Validation::Valid,
                    Err(e) => Validation::Invalid(e.into()),
                }
            }),
        }
    }

    ///Get the file path for the abi and parse it into an abi
    fn get_abi(&self) -> Result<ethers::abi::Abi> {
        let abi_path_string = self.get_abi_path_string()?;

        let mut parsed_abi = Self::parse_contract_abi(PathBuf::from(abi_path_string))
            .context("Failed to parse abi")?;

        parsed_abi.events = filter_duplicate_events(parsed_abi.events);

        Ok(parsed_abi)
    }

    ///Gets the network from from cli args or prompts for
    ///a network
    fn get_network(&self) -> Result<converters::NetworkKind> {
        match &self.blockchain {
            Some(b) => {
                let network_id: u64 = (b.clone()).into();
                get_converter_network_u64(network_id, &self.rpc_url, &self.start_block)
            }
            None => prompt_for_network_id(&self.rpc_url, &self.start_block, vec![]),
        }
    }

    ///Prompts for a contract name
    fn get_contract_name(&self) -> Result<String> {
        match &self.contract_name {
            Some(n) => Ok(n.clone()),
            None => prompt_contract_name(),
        }
    }
}

impl Contract for SelectedContract {
    fn get_network_name(&self) -> Result<String> {
        self.get_last_network_name()
    }

    fn get_name(&self) -> String {
        self.name.clone()
    }

    fn add_address(&mut self) -> Result<()> {
        let network = self.get_last_network_mut()?;
        let address = prompt_contract_address(Some(&network.addresses))
            .context("Failed prompting user for new address")?;
        network.addresses.push(address);
        Ok(())
    }

    fn add_network(&mut self) -> Result<()> {
        //In a new network case, no RPC url could be
        //derived from CLI flags
        const NO_RPC_URL: Option<String> = None;
        const NO_START_BLOCK: Option<u64> = None;

        //Select a new network (not from the list of existing network ids already added)
        let selected_network =
            prompt_for_network_id(&NO_RPC_URL, &NO_START_BLOCK, self.get_network_ids())
                .context("Failed selecting network")?;

        //Instantiate a network_selection without any  contract addresses
        let network_selection =
            ContractImportNetworkSelection::new_without_addresses(selected_network);

        //Add the network to the contract selection
        self.networks.push(network_selection);

        //Populate contract addresses with prompt
        self.add_address()?;

        Ok(())
    }
}

///Constructs SelectedContract via cli args and prompts
async fn get_contract_import_selection(args: ContractImportArgs) -> Result<SelectedContract> {
    //Construct SelectedContract via explorer or local import
    match &args.get_local_or_explorer_import()? {
        LocalOrExplorerImport::Explorer(explorer_import_args) => args
            .get_contract_import_selection_from_explore_import_args(explorer_import_args)
            .await
            .context("Failed getting SelectedContract from explorer"),
        LocalOrExplorerImport::Local(local_import_args) => args
            .get_contract_import_selection_from_local_import_args(local_import_args)
            .await
            .context("Failed getting local contract selection"),
    }
}

//Constructs SelectedContract via local prompt. Uses abis and manual
//network/contract config
async fn prompt_selected_contracts(args: ContractImportArgs) -> Result<Vec<SelectedContract>> {
    let should_prompt_to_continue_adding = !args.single_contract.clone();
    let first_contract = get_contract_import_selection(args).await?;
    let mut contracts = vec![first_contract];

    if should_prompt_to_continue_adding {
        prompt_to_continue_adding(
            &mut contracts,
            || get_contract_import_selection(ContractImportArgs::default()),
            true,
        )
        .await?
    }

    Ok(contracts)
}

pub async fn prompt_contract_import_init_flow(args: ContractImportArgs) -> Result<InitFlow> {
    Ok(InitFlow::ContractImport(ContractImportSelection {
        selected_contracts: prompt_selected_contracts(args)
            .await
            .context("Failed getting contract selection")?,
    }))
}
