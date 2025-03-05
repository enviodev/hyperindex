use clap::ValueEnum;
use serde::{Deserialize, Serialize};
use strum::{Display, EnumIter, EnumString};

pub mod evm {
    use std::collections::HashMap;

    use anyhow::{Context, Result};
    use clap::ValueEnum;
    use itertools::Itertools;
    use serde::{Deserialize, Serialize};
    use strum::{Display, EnumIter, EnumString};

    use crate::{
        config_parsing::{
            chain_helpers,
            contract_import::converters::{NetworkKind, SelectedContract},
            human_config::{
                evm::{ContractConfig, EventConfig, HumanConfig, Network, NetworkRpc},
                GlobalContract, NetworkContract,
            },
            system_config::EvmAbi,
        },
        utils::unique_hashmap,
    };

    use super::InitConfig;

    #[derive(Clone, Debug, ValueEnum, Serialize, Deserialize, EnumIter, EnumString, Display)]
    pub enum Template {
        Greeter,
        Erc20,
    }

    ///A an object that holds all the values a user can select during
    ///the auto config generation. Values can come from etherscan or
    ///abis etc.
    #[derive(Clone, Debug)]
    pub struct ContractImportSelection {
        pub selected_contracts: Vec<SelectedContract>,
    }

    ///Converts the selection object into a human config
    type ContractName = String;
    impl ContractImportSelection {
        pub fn to_human_config(&self, init_config: &InitConfig) -> Result<HumanConfig> {
            let mut networks_map: HashMap<u64, Network> = HashMap::new();
            let mut global_contracts: HashMap<ContractName, GlobalContract<ContractConfig>> =
                HashMap::new();

            for selected_contract in self.selected_contracts.clone() {
                let is_multi_chain_contract = selected_contract.networks.len() > 1;

                let events: Vec<EventConfig> = selected_contract
                    .events
                    .into_iter()
                    .map(|event| EventConfig {
                        event: EvmAbi::event_signature_from_abi_event(&event),
                        name: None,
                        field_selection: None,
                    })
                    .collect();

                let handler = init_config.language.get_event_handler_directory();

                let config = if is_multi_chain_contract {
                    //Add the contract to global contract config and return none for local contract
                    //config
                    let global_contract = GlobalContract {
                        name: selected_contract.name.clone(),
                        config: ContractConfig {
                            abi_file_path: None,
                            handler,
                            events,
                        },
                    };

                    unique_hashmap::try_insert(
                        &mut global_contracts,
                        selected_contract.name.clone(),
                        global_contract,
                    )
                    .context(format!(
                        "Unexpected, failed to add global contract {}. Contract should have \
                         unique names",
                        selected_contract.name
                    ))?;
                    None
                } else {
                    //Return some for local contract config
                    Some(ContractConfig {
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
                            let rpc = match &selected_network.network {
                                NetworkKind::Supported(_) => None,
                                NetworkKind::Unsupported { rpc_url, .. } => {
                                    Some(NetworkRpc::Url(rpc_url.to_string()))
                                }
                            };

                            let end_block = match selected_network.network {
                                NetworkKind::Supported(network) => {
                                    chain_helpers::Network::from(network).get_finite_end_block()
                                }
                                NetworkKind::Unsupported { network_id, .. } => {
                                    chain_helpers::Network::from_network_id(network_id)
                                        .ok()
                                        .and_then(|network| network.get_finite_end_block())
                                }
                            };

                            Network {
                                id: selected_network.network.get_network_id(),
                                hypersync_config: None,
                                rpc_config: None,
                                rpc,
                                start_block: selected_network.network.get_start_block(),
                                end_block,
                                confirmed_block_threshold: None,
                                contracts: Vec::new(),
                            }
                        });

                    let contract = NetworkContract {
                        name: selected_contract.name.clone(),
                        address,
                        config: config.clone(),
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

            Ok(HumanConfig {
                name: init_config.name.clone(),
                description: None,
                ecosystem: None,
                schema: None,
                contracts,
                networks: networks_map.into_values().sorted_by_key(|v| v.id).collect(),
                unordered_multichain_mode: Some(true),
                event_decoder: None,
                rollback_on_reorg: None,
                save_full_history: None,
                field_selection: None,
                raw_events: None,
            })
        }

        fn uses_hypersync(&self) -> bool {
            self.selected_contracts
                .iter()
                .any(|c| c.networks.iter().any(|n| n.uses_hypersync()))
        }
    }

    #[derive(Clone, Debug, Display)]
    pub enum InitFlow {
        Template(Template),
        SubgraphID(String),
        ContractImport(ContractImportSelection),
    }

    impl InitFlow {
        pub fn uses_hypersync(&self) -> bool {
            match self {
                Self::Template(_) => true,
                Self::ContractImport(selection) => selection.uses_hypersync(),
                Self::SubgraphID(_) => todo!("Subgraph migration not yet handled"),
            }
        }
    }
}

pub mod fuel {
    use std::collections::HashMap;

    use clap::ValueEnum;
    use serde::{Deserialize, Serialize};
    use strum::{Display, EnumIter, EnumString, IntoEnumIterator};

    use crate::{
        config_parsing::human_config::{
            fuel::{
                ContractConfig, EcosystemTag, EventConfig, HumanConfig, Network as NetworkConfig,
            },
            NetworkContract,
        },
        fuel::{abi::FuelAbi, address::Address},
    };

    use super::InitConfig;

    #[derive(Clone, Debug, ValueEnum, Serialize, Deserialize, EnumIter, EnumString, Display)]
    pub enum Template {
        Greeter,
    }

    #[derive(Clone, Debug, Display, Eq, Hash, PartialEq, EnumIter)]
    pub enum Network {
        Mainnet = 9889,
        Testnet = 0,
    }

    #[derive(Clone, Debug)]
    pub struct SelectedContract {
        pub name: String,
        pub addresses: Vec<Address>,
        pub abi: FuelAbi,
        pub selected_events: Vec<EventConfig>,
        pub network: Network,
    }

    impl SelectedContract {
        pub fn get_vendored_abi_file_path(&self) -> String {
            format!("abis/{}-abi.json", self.name.to_lowercase())
        }
    }

    #[derive(Clone, Debug)]
    pub struct ContractImportSelection {
        pub contracts: Vec<SelectedContract>,
    }

    impl ContractImportSelection {
        pub fn to_human_config(&self, init_config: &InitConfig) -> HumanConfig {
            let mut contracts_by_network: HashMap<Network, Vec<SelectedContract>> = HashMap::new();

            for contract in self.contracts.clone() {
                match contracts_by_network.get_mut(&contract.network) {
                    None => {
                        contracts_by_network.insert(contract.network.clone(), vec![contract]);
                    }
                    Some(contracts) => contracts.push(contract),
                }
            }

            let mut network_configs = vec![];
            for network in Network::iter() {
                match contracts_by_network.get(&network) {
                    None => (),
                    Some(contracts) => network_configs.push(NetworkConfig {
                        id: network as u64,
                        start_block: 0,
                        end_block: None,
                        hyperfuel_config: None,
                        contracts: contracts
                            .iter()
                            .map(|selected_contract| NetworkContract {
                                name: selected_contract.name.clone(),
                                address: selected_contract
                                    .addresses
                                    .iter()
                                    .map(|a| a.to_string())
                                    .collect::<Vec<String>>()
                                    .into(),
                                config: Some(ContractConfig {
                                    abi_file_path: selected_contract.get_vendored_abi_file_path(),
                                    handler: init_config.language.get_event_handler_directory(),
                                    events: selected_contract.selected_events.clone(),
                                }),
                            })
                            .collect(),
                    }),
                }
            }

            HumanConfig {
                name: init_config.name.clone(),
                description: None,
                ecosystem: EcosystemTag::Fuel,
                schema: None,
                contracts: None,
                raw_events: None,
                networks: network_configs,
            }
        }
    }

    #[derive(Clone, Debug, Display)]
    pub enum InitFlow {
        Template(Template),
        ContractImport(ContractImportSelection),
    }
}

#[derive(Clone, Debug, Display)]
pub enum Ecosystem {
    Evm { init_flow: evm::InitFlow },
    Fuel { init_flow: fuel::InitFlow },
}

impl Ecosystem {
    pub fn uses_hypersync(&self) -> bool {
        match self {
            Self::Evm { init_flow } => init_flow.uses_hypersync(),
            Self::Fuel { .. } => true,
        }
    }
}

#[derive(
    Clone, Debug, ValueEnum, Serialize, Deserialize, EnumIter, EnumString, PartialEq, Eq, Display,
)]
///Which language do you want to write in?
pub enum Language {
    #[clap(name = "javascript")]
    JavaScript,
    #[clap(name = "typescript")]
    TypeScript,
    #[clap(name = "rescript")]
    ReScript,
}

impl Language {
    // Logic to get the event handler directory based on the language
    pub fn get_event_handler_directory(&self) -> String {
        match self {
            Language::ReScript => "./src/EventHandlers.bs.js".to_string(),
            Language::TypeScript => "src/EventHandlers.ts".to_string(),
            Language::JavaScript => "./src/EventHandlers.js".to_string(),
        }
    }
}

#[derive(Clone, Debug)]
pub struct InitConfig {
    pub name: String,
    pub directory: String,
    pub ecosystem: Ecosystem,
    pub language: Language,
    pub api_token: Option<String>,
}
