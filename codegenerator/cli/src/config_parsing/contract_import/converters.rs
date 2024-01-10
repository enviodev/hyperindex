use super::etherscan_helpers::fetch_contract_auto_selection_from_etherscan;
use crate::{
    cli_args::clap_definitions::Language,
    config_parsing::{
        chain_helpers::{HypersyncNetwork, NetworkWithExplorer},
        human_config::{
            self, ConfigEvent, EventNameOrSig, GlobalContractConfig, HumanConfig,
            LocalContractConfig, RpcConfig, SyncSourceConfig,
        },
    },
    utils::{address_type::Address, unique_hashmap},
};
use anyhow::Context;
use itertools::{self, Itertools};
use std::{
    collections::HashMap,
    fmt::{self, Display},
};
use thiserror;

///A an object that holds all the values a user can select during
///the auto config generation. Values can come from etherscan or
///abis etc.
#[derive(Clone, Debug)]
pub struct AutoConfigSelection {
    pub project_name: String,
    selected_contracts: Vec<ContractImportSelection>,
    language: Language,
}

#[derive(thiserror::Error, Debug)]
pub enum AutoConfigError {
    #[error("Contract '{}' already exists in AutoConfigSelection", .0.name)]
    ContractNameExists(ContractImportSelection, AutoConfigSelection),
}

impl AutoConfigSelection {
    pub fn new(
        project_name: String,
        language: Language,
        selected_contract: ContractImportSelection,
    ) -> Self {
        Self {
            project_name,
            language,
            selected_contracts: vec![selected_contract],
        }
    }

    pub fn add_contract(
        mut self,
        contract: ContractImportSelection,
    ) -> Result<Self, AutoConfigError> {
        let contract_name_lower = contract.name.to_lowercase();
        let contract_name_exists = self
            .selected_contracts
            .iter()
            .find(|c| &c.name.to_lowercase() == &contract_name_lower)
            .is_some();

        if contract_name_exists {
            //TODO: Handle more cases gracefully like:
            // - contract + event is exact match, in which case it should just merge networks and
            // addresses
            // - Contract has some matching addresses to another contract but all different events
            // - Contract has some matching events as another contract?
            Err(AutoConfigError::ContractNameExists(contract, self))?
        } else {
            self.selected_contracts.push(contract);
            Ok(self)
        }
    }

    pub async fn from_etherscan(
        project_name: String,
        language: Language,
        network: &NetworkWithExplorer,
        address: Address,
    ) -> anyhow::Result<Self> {
        let selected_contract = fetch_contract_auto_selection_from_etherscan(address, network)
            .await
            .context("Failed fetching selected contract")?;

        Ok(Self::new(project_name, language, selected_contract))
    }
}

///The hierarchy is based on how you would add items to
///your selection as you go. Ie. Once you have constructed
///the selection of a contract you can add more addresses or
///networks
#[derive(Clone, Debug)]
pub struct ContractImportSelection {
    pub name: String,
    pub networks: Vec<ContractImportNetworkSelection>,
    pub events: Vec<ethers::abi::Event>,
}

impl ContractImportSelection {
    pub fn new(
        name: String,
        network_selection: ContractImportNetworkSelection,
        events: Vec<ethers::abi::Event>,
    ) -> Self {
        Self {
            name,
            networks: vec![network_selection],
            events,
        }
    }

    pub fn add_network(mut self, network_selection: ContractImportNetworkSelection) -> Self {
        self.networks.push(network_selection);
        self
    }

    pub async fn from_etherscan(
        network: &NetworkWithExplorer,
        address: Address,
    ) -> anyhow::Result<Self> {
        fetch_contract_auto_selection_from_etherscan(address, network).await
    }

    pub fn get_network_ids(&self) -> Vec<u64> {
        self.networks
            .iter()
            .map(|n| n.network.get_network_id())
            .collect()
    }
}

type NetworkId = u64;
type RpcUrl = String;

#[derive(Clone, Debug)]
pub enum Network {
    Supported(HypersyncNetwork),
    Unsupported(NetworkId, RpcUrl),
}

impl Network {
    pub fn get_network_id(&self) -> NetworkId {
        match self {
            Network::Supported(n) => n.clone() as u64,
            Network::Unsupported(n, _) => *n,
        }
    }
}

impl Display for Network {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match &self {
            Self::Supported(n) => write!(f, "{}", n),
            Self::Unsupported(n, _) => write!(f, "{}", n),
        }
    }
}

#[derive(Clone, Debug)]
pub struct ContractImportNetworkSelection {
    pub network: Network,
    pub addresses: Vec<Address>,
}

impl ContractImportNetworkSelection {
    pub fn new(network: Network, address: Address) -> Self {
        Self {
            network,
            addresses: vec![address],
        }
    }

    pub fn new_without_addresses(network: Network) -> Self {
        Self {
            network,
            addresses: vec![],
        }
    }

    pub fn add_address(mut self, address: Address) -> Self {
        self.addresses.push(address);

        self
    }
}

///Converts the selection object into a human config
type ContractName = String;
impl TryFrom<AutoConfigSelection> for HumanConfig {
    type Error = anyhow::Error;
    fn try_from(selection: AutoConfigSelection) -> Result<Self, Self::Error> {
        let mut networks_map: HashMap<u64, human_config::Network> = HashMap::new();
        let mut global_contracts: HashMap<ContractName, GlobalContractConfig> = HashMap::new();

        for selected_contract in selection.selected_contracts {
            let is_multi_chain_contract = selected_contract.networks.len() > 1;

            let events: Vec<ConfigEvent> = selected_contract
                .events
                .into_iter()
                .map(|event| human_config::ConfigEvent {
                    event: EventNameOrSig::Event(event.clone()),
                    required_entities: None,
                    is_async: None,
                })
                .collect();

            let handler = get_event_handler_directory(&selection.language);

            let local_contract_config = if is_multi_chain_contract {
                //Add the contract to global contract config and return none for local contract
                //config
                let global_contract = GlobalContractConfig {
                    name: selected_contract.name.clone(),
                    abi_file_path: None,
                    handler,
                    events,
                };

                unique_hashmap::try_insert(
                    &mut global_contracts,
                    selected_contract.name.clone(),
                    global_contract,
                )
                .context(format!(
                    "Unexpected, failed to add global contract {}. Contract should have unique names",
                    selected_contract.name
                ))?;
                None
            } else {
                //Return some for local contract config
                Some(LocalContractConfig {
                    abi_file_path: None,
                    handler,
                    events,
                })
            };

            for selected_network in &selected_contract.networks {
                let address = selected_network
                    .addresses
                    .iter()
                    .map(|a| a.to_string())
                    .collect::<Vec<_>>()
                    .into();

                let network = networks_map
                    .entry(selected_network.network.get_network_id())
                    .or_insert({
                        let sync_source = match &selected_network.network {
                            Network::Supported(_) => None,
                            Network::Unsupported(_, url) => {
                                Some(SyncSourceConfig::RpcConfig(RpcConfig {
                                    url: url.clone(),
                                    unstable__sync_config: None,
                                }))
                            }
                        };

                        human_config::Network {
                            id: selected_network.network.get_network_id(),
                            sync_source,
                            start_block: 0,
                            contracts: Vec::new(),
                        }
                    });

                let contract = human_config::NetworkContractConfig {
                    name: selected_contract.name.clone(),
                    address,
                    local_contract_config: local_contract_config.clone(),
                };

                network.contracts.push(contract);
            }
        }

        let contracts = match global_contracts
            .into_values()
            .sorted_by_key(|v| v.name.clone())
            .collect::<Vec<_>>()
        {
            values if values.is_empty() => None,
            values => Some(values),
        };

        let networks = networks_map.into_values().sorted_by_key(|v| v.id).collect();

        Ok(HumanConfig {
            name: selection.project_name,
            description: None,
            schema: None,
            contracts,
            networks,
        })
    }
}

// Logic to get the event handler directory based on the language
fn get_event_handler_directory(language: &Language) -> String {
    match language {
        Language::Rescript => "./src/EventHandlers.bs.js".to_string(),
        Language::Typescript => "src/EventHandlers.ts".to_string(),
        Language::Javascript => "./src/EventHandlers.js".to_string(),
    }
}
