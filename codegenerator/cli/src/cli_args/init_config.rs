use clap::ValueEnum;
use serde::{Deserialize, Serialize};
use strum::{Display, EnumIter, EnumString};

pub mod evm {
    use clap::ValueEnum;
    use serde::{Deserialize, Serialize};
    use strum::{Display, EnumIter, EnumString};

    use crate::config_parsing::contract_import::converters::AutoConfigSelection;

    #[derive(Clone, Debug, ValueEnum, Serialize, Deserialize, EnumIter, EnumString, Display)]
    pub enum Template {
        Greeter,
        Erc20,
    }

    #[derive(Clone, Debug, Display)]
    pub enum InitFlow {
        Template(Template),
        SubgraphID(String),
        ContractImport(AutoConfigSelection),
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
                networks: vec![human_config::evm::Network {
                    id: 1,
                    start_block: 0,
                    sync_source: None,
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
                                        is_async: None,
                                        required_entities: None,
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
