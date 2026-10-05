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
                evm::{Chain, ContractConfig, EventConfig, HumanConfig, RpcSelection},
                BaseConfig, ChainContract, GlobalContract, StartBlock,
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
        #[strum(serialize = "Feature: External Calls")]
        FeatureExternalCalls,
        #[strum(serialize = "Feature: Factory Contract")]
        FeatureFactory,
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
            let mut chains_map: HashMap<u64, Chain> = HashMap::new();
            let mut global_contracts: HashMap<ContractName, GlobalContract<ContractConfig>> =
                HashMap::new();

            for selected_contract in self.selected_contracts.clone() {
                let is_multi_chain_contract = selected_contract.chains.len() > 1;

                let events: Vec<EventConfig> = selected_contract
                    .events
                    .into_iter()
                    .map(|event| EventConfig {
                        event: EvmAbi::event_signature_from_abi_event(&event),
                        name: None,
                        field_selection: None,
                    })
                    .collect();

                let config = if is_multi_chain_contract {
                    //Add the contract to global contract config and return none for local contract
                    //config
                    let global_contract = GlobalContract {
                        name: selected_contract.name.clone(),
                        config: ContractConfig {
                            abi_file_path: None,
                            handler: None,
                            events: events.clone(),
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
                        handler: None,
                        events,
                    })
                };

                for selected_chain in &selected_contract.chains {
                    let address = selected_chain
                        .addresses
                        .iter()
                        .map(|a| a.to_string())
                        .collect::<Vec<_>>()
                        .into();

                    let chain = chains_map
                        .entry(selected_chain.network.get_network_id())
                        .or_insert({
                            let rpc = match &selected_chain.network {
                                NetworkKind::Supported(_) => None,
                                NetworkKind::Unsupported { rpc_url, .. } => {
                                    Some(RpcSelection::Url(rpc_url.to_string()))
                                }
                            };

                            let end_block = match selected_chain.network {
                                NetworkKind::Supported(network) => {
                                    chain_helpers::Network::from(network).get_finite_end_block()
                                }
                                NetworkKind::Unsupported { network_id, .. } => {
                                    chain_helpers::Network::from_network_id(network_id)
                                        .ok()
                                        .and_then(|network| network.get_finite_end_block())
                                }
                            };

                            Chain {
                                id: selected_chain.network.get_network_id(),
                                skip: None,
                                hypersync_config: None,
                                rpc,
                                start_block: StartBlock::Number(
                                    selected_chain.network.get_start_block(),
                                ),
                                end_block,
                                max_reorg_depth: None,
                                block_lag: None,
                                contracts: Some(Vec::new()),
                            }
                        });

                    let contract = ChainContract {
                        name: selected_contract.name.clone(),
                        address,
                        config: config.clone(),
                        start_block: None,
                    };

                    chain.contracts.get_or_insert_with(Vec::new).push(contract);
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
                base: BaseConfig {
                    name: init_config.name.clone(),
                    description: None,
                    schema: None,
                    handlers: None,
                    full_batch_size: None,
                    storage: None,
                    // The recommended mode for a new indexer: an entity id is
                    // scoped to its chain unless it opts into `@crossChain`.
                    disable_default_cross_chain: Some(true),
                },
                ecosystem: None,
                contracts,
                chains: chains_map.into_values().sorted_by_key(|v| v.id).collect(),
                rollback_on_reorg: None,
                save_full_history: None,
                field_selection: None,
                raw_events: None,
                bytes_type: None,
                address_format: None,
            })
        }

        fn uses_hypersync(&self) -> bool {
            self.selected_contracts
                .iter()
                .any(|c| c.chains.iter().any(|n| n.uses_hypersync()))
        }
    }

    #[derive(Clone, Debug, Display)]
    pub enum InitFlow {
        Template(Template),
        ContractImport(ContractImportSelection),
    }

    impl InitFlow {
        pub fn uses_hypersync(&self) -> bool {
            match self {
                Self::Template(_) => true,
                Self::ContractImport(selection) => selection.uses_hypersync(),
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
            fuel::{Chain as ChainConfig, ContractConfig, EcosystemTag, EventConfig, HumanConfig},
            BaseConfig, ChainContract, StartBlock,
        },
        fuel::{abi::FuelAbi, address::Address},
    };

    use super::InitConfig;

    #[derive(Clone, Debug, ValueEnum, Serialize, Deserialize, EnumIter, EnumString, Display)]
    pub enum Template {
        Greeter,
    }

    #[derive(Clone, Debug, Display, Eq, Hash, PartialEq, EnumIter, EnumString, ValueEnum)]
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
                    Some(contracts) => network_configs.push(ChainConfig {
                        id: network as u64,
                        skip: None,
                        start_block: StartBlock::Number(0),
                        end_block: None,
                        hyperfuel_config: None,
                        max_reorg_depth: None,
                        block_lag: None,
                        contracts: Some(
                            contracts
                                .iter()
                                .map(|selected_contract| ChainContract {
                                    name: selected_contract.name.clone(),
                                    address: selected_contract
                                        .addresses
                                        .iter()
                                        .map(|a| a.to_string())
                                        .collect::<Vec<String>>()
                                        .into(),
                                    config: Some(ContractConfig {
                                        abi_file_path: selected_contract
                                            .get_vendored_abi_file_path(),
                                        handler: None,
                                        events: selected_contract.selected_events.clone(),
                                    }),
                                    start_block: None,
                                })
                                .collect(),
                        ),
                    }),
                }
            }

            HumanConfig {
                base: BaseConfig {
                    name: init_config.name.clone(),
                    description: None,
                    schema: None,
                    handlers: None,
                    full_batch_size: None,
                    storage: None,
                    // The recommended mode for a new indexer: an entity id is
                    // scoped to its chain unless it opts into `@crossChain`.
                    disable_default_cross_chain: Some(true),
                },
                ecosystem: EcosystemTag::Fuel,
                contracts: None,
                raw_events: None,
                bytes_type: None,
                chains: network_configs,
            }
        }
    }

    #[derive(Clone, Debug, Display)]
    pub enum InitFlow {
        Template(Template),
        ContractImport(ContractImportSelection),
    }
}

pub mod svm {
    use clap::ValueEnum;
    use serde::{Deserialize, Serialize};
    use strum::{Display, EnumIter, EnumString};

    #[derive(Clone, Debug, ValueEnum, Serialize, Deserialize, EnumIter, EnumString, Display)]
    pub enum Template {
        #[strum(serialize = "USDC Transfers (SPL Token instructions)")]
        UsdcTransfers,
    }

    #[derive(Clone, Debug, Display)]
    pub enum InitFlow {
        Template(Template),
    }
}

#[derive(Clone, Debug, Display)]
pub enum Ecosystem {
    Evm { init_flow: evm::InitFlow },
    Svm { init_flow: svm::InitFlow },
    Fuel { init_flow: fuel::InitFlow },
}

impl Ecosystem {
    pub fn uses_hypersync(&self) -> bool {
        match self {
            Self::Evm { init_flow } => init_flow.uses_hypersync(),
            Self::Svm { .. } => true,
            Self::Fuel { .. } => true,
        }
    }
}

#[derive(
    Clone, Debug, ValueEnum, Serialize, Deserialize, EnumIter, EnumString, PartialEq, Eq, Display,
)]
///Which language do you want to write in?
pub enum Language {
    #[clap(name = "typescript")]
    TypeScript,
    #[clap(name = "rescript")]
    ReScript,
}

#[derive(
    Clone,
    Copy,
    Debug,
    ValueEnum,
    Serialize,
    Deserialize,
    EnumIter,
    EnumString,
    PartialEq,
    Eq,
    Display,
)]
pub enum PackageManager {
    #[clap(name = "pnpm")]
    #[strum(serialize = "pnpm")]
    Pnpm,
    #[clap(name = "npm")]
    #[strum(serialize = "npm")]
    Npm,
    #[clap(name = "yarn")]
    #[strum(serialize = "yarn")]
    Yarn,
    #[clap(name = "bun")]
    #[strum(serialize = "bun")]
    Bun,
}

impl PackageManager {
    /// Shell command used for `install` and `run <script>` invocations.
    pub fn cmd(&self) -> &'static str {
        match self {
            PackageManager::Pnpm => "pnpm",
            PackageManager::Npm => "npm",
            PackageManager::Yarn => "yarn",
            PackageManager::Bun => "bun",
        }
    }

    /// What a user types to run a package.json script. npm and bun only run
    /// custom scripts through `run`.
    pub fn run_script_command(&self, script: &str) -> String {
        match self {
            PackageManager::Pnpm | PackageManager::Yarn => format!("{} {script}", self.cmd()),
            PackageManager::Npm | PackageManager::Bun => format!("{} run {script}", self.cmd()),
        }
    }

    pub fn install_command(&self) -> String {
        format!("{} install", self.cmd())
    }

    /// Runs a binary installed in the project's node_modules.
    pub fn exec_command(&self, binary: &str) -> String {
        match self {
            PackageManager::Pnpm | PackageManager::Yarn => format!("{} {binary}", self.cmd()),
            PackageManager::Npm => format!("npx {binary}"),
            PackageManager::Bun => format!("bunx {binary}"),
        }
    }

    /// The package manager whose lockfile the project has.
    pub fn detect(project_root: &std::path::Path) -> Option<Self> {
        [
            ("pnpm-lock.yaml", PackageManager::Pnpm),
            ("package-lock.json", PackageManager::Npm),
            ("yarn.lock", PackageManager::Yarn),
            ("bun.lock", PackageManager::Bun),
            ("bun.lockb", PackageManager::Bun),
        ]
        .into_iter()
        .find(|(lockfile, _)| project_root.join(lockfile).is_file())
        .map(|(_, pm)| pm)
    }

    /// The templates' docs spell commands with pnpm. This rewrites the ones
    /// they use, scripts, `install` and `tsc`, and leaves any other `pnpm`
    /// command as written.
    pub fn rewrite_commands(&self, text: &str) -> String {
        let mut out = String::with_capacity(text.len());
        let mut rest = text;
        while let Some(at) = rest.find("pnpm ") {
            let starts_word = rest[..at]
                .chars()
                .last()
                .is_none_or(|c| !c.is_ascii_alphanumeric());
            let after = &rest[at + "pnpm ".len()..];
            let word_end = after
                .find(|c: char| !(c.is_ascii_alphanumeric() || c == '-'))
                .unwrap_or(after.len());
            let word = &after[..word_end];
            let replacement = match word {
                _ if !starts_word => None,
                "build" | "codegen" | "dev" | "start" | "test" => {
                    Some(self.run_script_command(word))
                }
                "install" => Some(self.install_command()),
                "tsc" => Some(self.exec_command("tsc")),
                _ => None,
            };
            out.push_str(&rest[..at]);
            match replacement {
                Some(replacement) => out.push_str(&replacement),
                None => {
                    out.push_str("pnpm ");
                    out.push_str(word);
                }
            }
            rest = &after[word_end..];
        }
        out.push_str(rest);
        out
    }

    /// Default when `--package-manager` isn't given: `pnpm` if it's on the
    /// PATH, otherwise `npm`. Node.js ships with `npm`, so it's always
    /// available as the last-resort fallback.
    pub fn resolve_default() -> Self {
        let pnpm_available = std::process::Command::new("pnpm")
            .arg("--version")
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status()
            .map(|s| s.success())
            .unwrap_or(false);
        if pnpm_available {
            PackageManager::Pnpm
        } else {
            PackageManager::Npm
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
    pub package_manager: PackageManager,
}
