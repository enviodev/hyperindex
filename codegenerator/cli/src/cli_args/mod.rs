use clap::{Args, Parser, Subcommand, ValueEnum};
use serde::{Deserialize, Serialize};
use strum_macros::{Display, EnumIter, EnumString};

use self::interactive_init::InitInteractive;
pub mod constants;
pub mod interactive_init;
pub mod validation;

use crate::config_parsing::chain_helpers::NetworkWithExplorer;

#[derive(Debug, Parser)]
#[clap(author, version, about)]
pub struct CommandLineArgs {
    #[clap(subcommand)]
    pub command: CommandType,
}

#[derive(Debug, Subcommand)]
pub enum CommandType {
    ///Initialize a project with a template
    Init(InitArgs),

    /// Development commands for starting, stopping, and restarting the local environment        
    Dev,

    /// Stop the local environment - delete the database and stop all processes (including Docker) for the current directory
    Stop,

    ///Generate code from a config.yaml & schema.graphql file
    Codegen(CodegenArgs),

    ///Prepare local environment for envio testing
    // #[clap(hide = true)]
    #[command(subcommand)]
    Local(LocalCommandTypes),

    ///Start the indexer
    Start(StartArgs),

    ///Print help into a markdown file
    ///Command to run: cargo run --bin envio -- print-all-help > CommandLineHelp.md
    #[clap(hide = true)]
    PrintAllHelp,
}

#[derive(Debug, Args)]
pub struct StartArgs {
    ///Clear your database and restart indexing from scratch
    #[arg(short = 'r', long, default_value_t = false)]
    pub restart: bool,
    ///The directory of the project
    #[arg(short, long, default_value_t=String::from(constants::DEFAULT_PROJECT_ROOT_PATH))]
    pub directory: String,
}

#[derive(Debug, Subcommand)]
pub enum LocalCommandTypes {
    /// Local Envio and ganache environment commands
    #[command(subcommand)]
    Docker(LocalDockerSubcommands),
    /// Local Envio database commands
    #[command(subcommand)]
    DbMigrate(DbMigrateSubcommands),
}

#[derive(Subcommand, Debug, Clone)]
pub enum LocalDockerSubcommands {
    ///Run docker compose up -d on generated/docker-compose.yaml
    Up,
    ///Run docker compose down -v on generated/docker-compose.yaml
    Down,
}

#[derive(Subcommand, Debug)]
pub enum DbMigrateSubcommands {
    ///Migrate latest schema to database
    Up,
    ///Drop database schema
    Down,
    ///Setup database by dropping schema and then running migrations
    Setup,
}
#[derive(Args, Debug)]
pub struct CodegenArgs {
    ///The directory of the project
    #[arg(short, long, default_value_t=String::from(constants::DEFAULT_PROJECT_ROOT_PATH))]
    pub directory: String,

    ///The directory within the project that generated code should output to
    #[arg(short, long, default_value_t=String::from(constants::DEFAULT_GENERATED_PATH))]
    pub output_directory: String,

    ///The file in the project containing config.
    #[arg(short, long, default_value_t=String::from(constants::DEFAULT_CONFIG_PATH))]
    pub config: String,
}

type SubgraphMigrationID = String;
type ContractAddress = String;

#[derive(Args, Debug)]
pub struct InitArgs {
    ///The directory of the project
    // #[arg(short, long, default_value_t=String::from(DEFAULT_PROJECT_ROOT_PATH))]
    #[arg(short, long)]
    pub directory: Option<String>,

    ///The name of your project
    #[arg(short, long)]
    pub name: Option<String>,

    ///The options for how to initialize
    #[command(subcommand)]
    init_commands: Option<InitFlow>,

    ///The language used to write handlers
    #[arg(short = 'l', long = "language")]
    #[clap(value_enum)]
    pub language: Option<Language>,
}

#[derive(Subcommand, Debug, EnumIter, Display, EnumString)]
enum InitFlow {
    ///Start from an example template
    Template(TemplateArgs),
    ///Start by migrating config from an existing subgraph
    SubgraphMigration(SubgraphMigrationArgs),
    ///Import config for a contract address for a given chain
    Import(ContractMigrationArgs),
}

#[derive(Args, Debug, Default)]
pub struct TemplateArgs {
    ///The file in the project containing config.
    #[arg(short, long)]
    #[clap(value_enum)]
    pub name: Option<Template>,
}

#[derive(Args, Debug, Default)]
pub struct SubgraphMigrationArgs {
    ///Subgraph ID to start a migration from
    #[arg(short, long)]
    pub subgraph_id: Option<SubgraphMigrationID>,
}

#[derive(Args, Debug, Default)]
pub struct ContractMigrationArgs {
    ///Network from which contract address should be fetched for migration
    #[arg(short, long)]
    pub blockchain: Option<NetworkWithExplorer>,

    ///Contract address to generate the config from
    #[arg(short, long)]
    pub contract_address: Option<ContractAddress>,
}

#[derive(Clone, Debug, ValueEnum, Serialize, Deserialize, EnumIter, EnumString, Display)]
///Template to work off
pub enum Template {
    Blank,
    Greeter,
    Erc20,
}

#[derive(
    Clone, Debug, ValueEnum, Serialize, Deserialize, EnumIter, EnumString, PartialEq, Eq, Display,
)]
///Which language do you want to write in?
pub enum Language {
    Javascript,
    Typescript,
    Rescript,
}

pub struct ProjectPathsArgs {
    pub project_root: String,
    pub generated: String,
    pub config: String,
}

impl ProjectPathsArgs {
    pub fn default() -> Self {
        ProjectPathsArgs {
            project_root: constants::DEFAULT_PROJECT_ROOT_PATH.to_string(),
            generated: constants::DEFAULT_GENERATED_PATH.to_string(),
            config: constants::DEFAULT_CONFIG_PATH.to_string(),
        }
    }
}

pub trait ToProjectPathsArgs {
    fn to_project_paths_args(&self) -> ProjectPathsArgs;
}

impl ToProjectPathsArgs for CodegenArgs {
    fn to_project_paths_args(&self) -> ProjectPathsArgs {
        ProjectPathsArgs {
            project_root: self.directory.clone(),
            generated: self.output_directory.clone(),
            config: self.config.clone(),
        }
    }
}

impl ToProjectPathsArgs for InitInteractive {
    fn to_project_paths_args(&self) -> ProjectPathsArgs {
        ProjectPathsArgs {
            project_root: self.directory.clone(),
            generated: constants::DEFAULT_GENERATED_PATH.to_string(),
            config: constants::DEFAULT_CONFIG_PATH.to_string(),
        }
    }
}

impl ToProjectPathsArgs for StartArgs {
    fn to_project_paths_args(&self) -> ProjectPathsArgs {
        ProjectPathsArgs {
            project_root: self.directory.clone(),
            generated: constants::DEFAULT_GENERATED_PATH.to_string(),
            config: constants::DEFAULT_CONFIG_PATH.to_string(),
        }
    }
}
