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
            contract_import::converters::{NetworkKind, SelectedContract},
            human_config::{
                evm::{ContractConfig, EventConfig, HumanConfig, Network, RpcConfig},
                GlobalContract, NetworkContract,
            },
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
        pub fn to_human_config(self: &Self, init_config: &InitConfig) -> Result<HumanConfig> {
            let mut networks_map: HashMap<u64, Network> = HashMap::new();
            let mut global_contracts: HashMap<ContractName, GlobalContract<ContractConfig>> =
                HashMap::new();

            for selected_contract in self.selected_contracts.clone() {
                let is_multi_chain_contract = selected_contract.networks.len() > 1;

                let events: Vec<EventConfig> = selected_contract
                    .events
                    .into_iter()
                    .map(|event| EventConfig {
                        event: EventConfig::event_string_from_abi_event(&event),
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
                            let rpc_config = match &selected_network.network {
                                NetworkKind::Supported(_) => None,
                                NetworkKind::Unsupported(_, url) => Some(RpcConfig {
                                    url: url.clone().into(),
                                    unstable__sync_config: None,
                                }),
                            };

                            Network {
                                id: selected_network.network.get_network_id(),
                                hypersync_config: None,
                                rpc_config,
                                start_block: 0,
                                end_block: None,
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
                unordered_multichain_mode: None,
                event_decoder: None,
                rollback_on_reorg: None,
                save_full_history: None,
                field_selection: None,
                raw_events: None,
            })
        }
    }

    #[derive(Clone, Debug, Display)]
    pub enum InitFlow {
        Template(Template),
        SubgraphID(String),
        ContractImport(ContractImportSelection),
    }
}

pub mod fuel {
    use clap::ValueEnum;
    use serde::{Deserialize, Serialize};
    use strum::{Display, EnumIter, EnumString};

    use crate::{
        config_parsing::human_config::{
            self,
            fuel::{ContractConfig, EcosystemTag, EventConfig, HumanConfig, Network},
            NetworkContract,
        },
        fuel::{
            abi::{Abi, FuelLog},
            address::Address,
        },
    };

    use super::InitConfig;

    #[derive(Clone, Debug, ValueEnum, Serialize, Deserialize, EnumIter, EnumString, Display)]
    pub enum Template {
        Greeter,
    }

    #[derive(Clone, Debug)]
    pub struct SelectedContract {
        pub name: String,
        pub addresses: Vec<Address>,
        pub abi: Abi,
        pub selected_logs: Vec<FuelLog>,
    }

    impl SelectedContract {
        pub fn get_vendored_abi_file_path(self: &Self) -> String {
            format!("abis/{}-abi.json", self.name.to_lowercase())
        }
    }

    #[derive(Clone, Debug)]
    pub struct ContractImportSelection {
        pub contracts: Vec<SelectedContract>,
    }

    impl ContractImportSelection {
        pub fn to_human_config(self: &Self, init_config: &InitConfig) -> HumanConfig {
            HumanConfig {
                name: init_config.name.clone(),
                description: None,
                ecosystem: EcosystemTag::Fuel,
                schema: None,
                contracts: None,
                networks: vec![Network {
                    id: 0,
                    start_block: 0,
                    end_block: None,
                    contracts: self
                        .contracts
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
                                events: selected_contract
                                    .selected_logs
                                    .iter()
                                    .map(|selected_log| EventConfig {
                                        name: selected_log.event_name.clone(),
                                        log_id: selected_log.id.clone().into(),
                                    })
                                    .collect(),
                            }),
                        })
                        .collect(),
                }],
            }
        }

        pub fn to_evm_human_config(
            self: &Self,
            init_config: &InitConfig,
        ) -> human_config::evm::HumanConfig {
            human_config::evm::HumanConfig {
                name: init_config.name.clone(),
                description: None,
                ecosystem: None,
                schema: None,
                unordered_multichain_mode: None,
                event_decoder: None,
                rollback_on_reorg: None,
                save_full_history: None,
                contracts: None,
                field_selection: None,
                raw_events: None,
                networks: vec![human_config::evm::Network {
                    id: 1,
                    start_block: 0,
                    hypersync_config: None,
                    rpc_config: None,
                    confirmed_block_threshold: None,
                    end_block: None,
                    contracts: self
                        .contracts
                        .iter()
                        .map(|selected_contract| NetworkContract {
                            name: selected_contract.name.clone(),
                            address: selected_contract
                                .addresses
                                .iter()
                                .map(|a| a.to_string())
                                .collect::<Vec<String>>()
                                .into(),
                            config: Some(human_config::evm::ContractConfig {
                                abi_file_path: None,
                                handler: init_config.language.get_event_handler_directory(),
                                events: selected_contract
                                    .selected_logs
                                    .iter()
                                    .map(|selected_log| human_config::evm::EventConfig {
                                        event: format!("{}()", selected_log.event_name),
                                    })
                                    .collect(),
                            }),
                        })
                        .collect(),
                }],
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
    pub fn get_event_handler_directory(self: &Self) -> String {
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
}
