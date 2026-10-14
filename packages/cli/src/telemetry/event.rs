//! The wire format. Every string a batch carries is an enum variant, a UUID or
//! a build constant, so nothing a user typed can reach it: no names,
//! addresses, ABIs, paths, URLs or environment values.

use crate::{
    cli_args::{
        clap_definitions::{
            CommandType, ConfigSubcommand, DbMigrateSubcommands, LocalCommandTypes,
            LocalDockerSubcommands, MetricsSubcommand, SkillsSubcommand, ToolsSubcommand,
        },
        init_config::{self, InitConfig},
    },
    config_parsing::{
        entity_parsing::DefaultChainScope,
        human_config::{evm::For, HumanConfig},
        hypersync_endpoints,
        system_config::{self, DataSource, MainEvmDataSource, SystemConfig},
    },
};
use serde::Serialize;
use std::collections::{BTreeMap, BTreeSet};
use std::time::Duration;
use strum::EnumString;

pub const SCHEMA_VERSION: u32 = 1;

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Batch {
    pub schema_version: u32,
    pub context: Context,
    pub events: Vec<Event>,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Context {
    pub install_id: Option<String>,
    /// One per process: ties a run's command event to its heartbeats.
    pub session_id: String,
    pub envio_version: String,
    pub os: String,
    pub arch: String,
    pub node_major: Option<u32>,
    pub ci: bool,
    pub environment: Environment,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Environment {
    Local,
    Docker,
    Kubernetes,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Event {
    Command(CommandEvent),
    Heartbeat(HeartbeatEvent),
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct CommandEvent {
    pub indexer_id: Option<String>,
    pub command: CommandName,
    pub outcome: Outcome,
    pub error_class: Option<ErrorClass>,
    pub duration: DurationBucket,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub init: Option<InitChoice>,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct HeartbeatEvent {
    pub indexer_id: Option<String>,
    pub reason: HeartbeatReason,
    #[serde(flatten)]
    pub profile: IndexerProfile,
    pub sync_state: SyncState,
    pub uptime: UptimeBucket,
    pub events_processed: EventsBucket,
    /// Errors seen since the previous heartbeat, by class.
    pub errors: BTreeMap<ErrorClass, u32>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum CommandName {
    Init,
    Codegen,
    Dev,
    Start,
    Stop,
    LocalDockerUp,
    LocalDockerDown,
    LocalDbMigrateUp,
    LocalDbMigrateDown,
    LocalDbMigrateSetup,
    Metrics,
    MetricsRuntime,
    SkillsUpdate,
    ToolsSearchDocs,
    ToolsFetchDocs,
    ConfigView,
}

impl CommandName {
    /// `None` for the commands that report nothing: `envio telemetry` itself,
    /// and the hidden scripts the repo's own build runs.
    pub fn of(command: &CommandType) -> Option<Self> {
        Some(match command {
            CommandType::Init(_) => Self::Init,
            CommandType::Codegen => Self::Codegen,
            CommandType::Dev(_) => Self::Dev,
            CommandType::Start(_) => Self::Start,
            CommandType::Stop => Self::Stop,
            CommandType::Local(LocalCommandTypes::Docker(LocalDockerSubcommands::Up)) => {
                Self::LocalDockerUp
            }
            CommandType::Local(LocalCommandTypes::Docker(LocalDockerSubcommands::Down)) => {
                Self::LocalDockerDown
            }
            CommandType::Local(LocalCommandTypes::DbMigrate(DbMigrateSubcommands::Up)) => {
                Self::LocalDbMigrateUp
            }
            CommandType::Local(LocalCommandTypes::DbMigrate(DbMigrateSubcommands::Down)) => {
                Self::LocalDbMigrateDown
            }
            CommandType::Local(LocalCommandTypes::DbMigrate(DbMigrateSubcommands::Setup)) => {
                Self::LocalDbMigrateSetup
            }
            CommandType::Metrics(args) => match args.subcommand {
                Some(MetricsSubcommand::Runtime) => Self::MetricsRuntime,
                None => Self::Metrics,
            },
            CommandType::Skills(SkillsSubcommand::Update) => Self::SkillsUpdate,
            CommandType::Tools(ToolsSubcommand::SearchDocs(_)) => Self::ToolsSearchDocs,
            CommandType::Tools(ToolsSubcommand::FetchDocs(_)) => Self::ToolsFetchDocs,
            CommandType::Config(ConfigSubcommand::View) => Self::ConfigView,
            CommandType::Telemetry(_) | CommandType::Script(_) => return None,
        })
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Outcome {
    Success,
    Failure,
    /// The user backed out of an `envio init` prompt.
    Cancelled,
    /// `envio init` run by an AI agent, which prints setup steps and stops.
    AgentPrompt,
}

#[derive(
    Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, EnumString, strum::Display,
)]
#[serde(rename_all = "snake_case")]
#[strum(serialize_all = "snake_case")]
pub enum ErrorClass {
    Config,
    Codegen,
    Docker,
    Database,
    Network,
    PackageManager,
    Io,
    Handler,
    Source,
    RateLimited,
    Other,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub enum DurationBucket {
    #[serde(rename = "0-1s")]
    UnderOneSecond,
    #[serde(rename = "1-5s")]
    OneToFiveSeconds,
    #[serde(rename = "5-30s")]
    FiveToThirtySeconds,
    #[serde(rename = "30s-2m")]
    ThirtySecondsToTwoMinutes,
    #[serde(rename = "2-10m")]
    TwoToTenMinutes,
    #[serde(rename = "10m+")]
    OverTenMinutes,
}

impl DurationBucket {
    pub fn of(duration: Duration) -> Self {
        match duration.as_secs_f64() {
            s if s < 1.0 => Self::UnderOneSecond,
            s if s < 5.0 => Self::OneToFiveSeconds,
            s if s < 30.0 => Self::FiveToThirtySeconds,
            s if s < 120.0 => Self::ThirtySecondsToTwoMinutes,
            s if s < 600.0 => Self::TwoToTenMinutes,
            _ => Self::OverTenMinutes,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub enum UptimeBucket {
    #[serde(rename = "0-1h")]
    UnderOneHour,
    #[serde(rename = "1-6h")]
    OneToSixHours,
    #[serde(rename = "6-24h")]
    SixToTwentyFourHours,
    #[serde(rename = "1-7d")]
    OneToSevenDays,
    #[serde(rename = "7d+")]
    OverSevenDays,
}

impl UptimeBucket {
    pub fn of(seconds: f64) -> Self {
        const HOUR: f64 = 3600.0;
        match seconds {
            s if s < HOUR => Self::UnderOneHour,
            s if s < 6.0 * HOUR => Self::OneToSixHours,
            s if s < 24.0 * HOUR => Self::SixToTwentyFourHours,
            s if s < 7.0 * 24.0 * HOUR => Self::OneToSevenDays,
            _ => Self::OverSevenDays,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub enum EventsBucket {
    #[serde(rename = "0")]
    None,
    #[serde(rename = "1-1k")]
    UpToOneThousand,
    #[serde(rename = "1k-100k")]
    UpToHundredThousand,
    #[serde(rename = "100k-10m")]
    UpToTenMillion,
    #[serde(rename = "10m+")]
    OverTenMillion,
}

impl EventsBucket {
    pub fn of(count: f64) -> Self {
        match count {
            c if c < 1.0 => Self::None,
            c if c <= 1_000.0 => Self::UpToOneThousand,
            c if c <= 100_000.0 => Self::UpToHundredThousand,
            c if c <= 10_000_000.0 => Self::UpToTenMillion,
            _ => Self::OverTenMillion,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, EnumString)]
#[serde(rename_all = "snake_case")]
#[strum(serialize_all = "snake_case")]
pub enum HeartbeatReason {
    Start,
    Interval,
    Crash,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum SyncState {
    Backfilling,
    Synced,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Ecosystem {
    Evm,
    Fuel,
    Svm,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Language {
    Typescript,
    Rescript,
}

impl From<&init_config::Language> for Language {
    fn from(language: &init_config::Language) -> Self {
        match language {
            init_config::Language::TypeScript => Self::Typescript,
            init_config::Language::ReScript => Self::Rescript,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct InitChoice {
    pub ecosystem: Ecosystem,
    pub flow: InitFlow,
    pub template: Option<InitTemplate>,
    pub language: Language,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum InitFlow {
    Template,
    ContractImport,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum InitTemplate {
    Greeter,
    Erc20,
    FeatureExternalCalls,
    FeatureFactory,
    UsdcTransfers,
}

impl InitChoice {
    pub fn of(init_config: &InitConfig) -> Self {
        use init_config::{evm, fuel, svm, Ecosystem as Chosen};
        let (ecosystem, template) = match &init_config.ecosystem {
            Chosen::Evm { init_flow } => (
                Ecosystem::Evm,
                match init_flow {
                    evm::InitFlow::Template(evm::Template::Greeter) => Some(InitTemplate::Greeter),
                    evm::InitFlow::Template(evm::Template::Erc20) => Some(InitTemplate::Erc20),
                    evm::InitFlow::Template(evm::Template::FeatureExternalCalls) => {
                        Some(InitTemplate::FeatureExternalCalls)
                    }
                    evm::InitFlow::Template(evm::Template::FeatureFactory) => {
                        Some(InitTemplate::FeatureFactory)
                    }
                    evm::InitFlow::ContractImport(_) => None,
                },
            ),
            Chosen::Fuel { init_flow } => (
                Ecosystem::Fuel,
                match init_flow {
                    fuel::InitFlow::Template(fuel::Template::Greeter) => {
                        Some(InitTemplate::Greeter)
                    }
                    fuel::InitFlow::ContractImport(_) => None,
                },
            ),
            Chosen::Svm {
                init_flow: svm::InitFlow::Template(svm::Template::UsdcTransfers),
            } => (Ecosystem::Svm, Some(InitTemplate::UsdcTransfers)),
        };
        Self {
            ecosystem,
            flow: if template.is_some() {
                InitFlow::Template
            } else {
                InitFlow::ContractImport
            },
            template,
            language: Language::from(&init_config.language),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum SourceKind {
    Hypersync,
    /// A HyperSync URL other than the chain's default one.
    HypersyncCustom,
    Rpc,
    RpcFallback,
    RpcRealtime,
    RpcWs,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum StorageKind {
    Postgres,
    Clickhouse,
}

/// Config features come from config.yaml; the others only the running indexer
/// sees, from what the handlers registered.
#[derive(
    Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, EnumString, strum::Display,
)]
#[serde(rename_all = "snake_case")]
#[strum(serialize_all = "snake_case")]
pub enum Feature {
    RawEvents,
    FullHistory,
    FieldSelection,
    PerChainEntities,
    EndBlock,
    ReorgRollbackDisabled,
    LowercaseAddresses,
    Effects,
    ContractRegister,
    Wildcard,
    BlockHandlers,
    DevMode,
    SplitRun,
    IsolatedChains,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct ChainProfile {
    pub chain_id: u64,
    pub sources: BTreeSet<SourceKind>,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct IndexerProfile {
    pub ecosystem: Ecosystem,
    pub language: Language,
    pub chains: Vec<ChainProfile>,
    pub contracts: usize,
    pub events: usize,
    pub entities: usize,
    pub storage: BTreeSet<StorageKind>,
    pub features: BTreeSet<Feature>,
}

impl IndexerProfile {
    pub fn of(config: &SystemConfig) -> Self {
        let mut chains: Vec<ChainProfile> = config
            .chains
            .values()
            .filter(|chain| !chain.skip)
            .map(|chain| ChainProfile {
                chain_id: chain.id,
                sources: sources_of(chain),
            })
            .collect();
        chains.sort_by_key(|chain| chain.chain_id);

        let mut storage = BTreeSet::new();
        if config.storage.postgres.is_some() {
            storage.insert(StorageKind::Postgres);
        }
        if config.storage.clickhouse.is_some() {
            storage.insert(StorageKind::Clickhouse);
        }

        let global_field_selection = match &config.human_config {
            HumanConfig::Evm(evm) => evm.field_selection.is_some(),
            HumanConfig::Fuel(_) | HumanConfig::Svm(_) => false,
        };
        let event_field_selection = config
            .contracts
            .values()
            .flat_map(|contract| &contract.events)
            .any(|event| event.field_selection.is_some());

        let features = [
            (config.enable_raw_events, Feature::RawEvents),
            (config.save_full_history, Feature::FullHistory),
            (
                global_field_selection || event_field_selection,
                Feature::FieldSelection,
            ),
            (
                config.default_chain_scope == DefaultChainScope::PerChain,
                Feature::PerChainEntities,
            ),
            (
                config
                    .chains
                    .values()
                    .any(|chain| !chain.skip && chain.end_block.is_some()),
                Feature::EndBlock,
            ),
            (!config.rollback_on_reorg, Feature::ReorgRollbackDisabled),
            (config.lowercase_addresses, Feature::LowercaseAddresses),
        ]
        .into_iter()
        .filter_map(|(on, feature)| on.then_some(feature))
        .collect();

        Self {
            ecosystem: match config.get_ecosystem() {
                system_config::Ecosystem::Evm => Ecosystem::Evm,
                system_config::Ecosystem::Fuel => Ecosystem::Fuel,
                system_config::Ecosystem::Svm => Ecosystem::Svm,
            },
            language: if config.is_rescript {
                Language::Rescript
            } else {
                Language::Typescript
            },
            chains,
            contracts: config.contracts.len(),
            events: config
                .contracts
                .values()
                .map(|contract| contract.events.len())
                .sum(),
            entities: config.schema.entities.len(),
            storage,
            features,
        }
    }
}

fn sources_of(chain: &system_config::Chain) -> BTreeSet<SourceKind> {
    let mut sources = BTreeSet::new();
    match &chain.sync_source {
        DataSource::Evm { main, rpcs } => {
            match main {
                MainEvmDataSource::HyperSync {
                    hypersync_endpoint_url,
                } => {
                    let is_default = hypersync_endpoints::get_default_hypersync_endpoint(chain.id)
                        .is_ok_and(|default| {
                            default.trim_end_matches('/') == hypersync_endpoint_url
                        });
                    sources.insert(if is_default {
                        SourceKind::Hypersync
                    } else {
                        SourceKind::HypersyncCustom
                    });
                }
                MainEvmDataSource::Rpc(_) => {
                    sources.insert(SourceKind::Rpc);
                }
            }
            for rpc in rpcs {
                sources.insert(match rpc.source_for {
                    Some(For::Fallback) => SourceKind::RpcFallback,
                    Some(For::Realtime) => SourceKind::RpcRealtime,
                    Some(For::Sync) | None => SourceKind::Rpc,
                });
                if rpc.ws.is_some() {
                    sources.insert(SourceKind::RpcWs);
                }
            }
        }
        DataSource::Fuel { .. } | DataSource::Svm { .. } => {
            sources.insert(SourceKind::Hypersync);
        }
    }
    sources
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn buckets_split_at_their_edges() {
        assert_eq!(
            (
                [0.4, 1.0, 29.9, 30.0, 599.0, 600.0]
                    .map(|s| DurationBucket::of(Duration::from_secs_f64(s))),
                [0.0, 3_600.0, 86_399.0, 604_800.0].map(UptimeBucket::of),
                [0.0, 1.0, 1_000.0, 1_001.0, 10_000_001.0].map(EventsBucket::of),
            ),
            (
                [
                    DurationBucket::UnderOneSecond,
                    DurationBucket::OneToFiveSeconds,
                    DurationBucket::FiveToThirtySeconds,
                    DurationBucket::ThirtySecondsToTwoMinutes,
                    DurationBucket::TwoToTenMinutes,
                    DurationBucket::OverTenMinutes,
                ],
                [
                    UptimeBucket::UnderOneHour,
                    UptimeBucket::OneToSixHours,
                    UptimeBucket::SixToTwentyFourHours,
                    UptimeBucket::OverSevenDays,
                ],
                [
                    EventsBucket::None,
                    EventsBucket::UpToOneThousand,
                    EventsBucket::UpToOneThousand,
                    EventsBucket::UpToHundredThousand,
                    EventsBucket::OverTenMillion,
                ],
            )
        );
    }
}
