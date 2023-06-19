use clap::{Args, Parser, Subcommand, ValueEnum};
use serde::{Deserialize, Serialize};
pub mod interactive_init;

pub const DEFAULT_PROJECT_ROOT_PATH: &str = "./";
pub const DEFAULT_GENERATED_PATH: &str = "generated/";
pub const DEFAULT_CONFIG_PATH: &str = "config.yaml";

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

    ///Generate code from a config.yaml & schema.graphql file
    Codegen(CodegenArgs),

    ///Prepare local environment for envio testing
    #[command(subcommand)]
    Local(LocalCommandTypes),

    ///Start the indexer
    Start(StartArgs),

    ///Print help into a markdown file
    ///Command to run: cargo run -- print-all-help > CommandLineHelp.md
    #[clap(hide = true)]
    PrintAllHelp,
}

#[derive(Debug, Args)]
pub struct StartArgs {
    ///Clear your database and restart indexing from scratch
    #[arg(short = 'r', long, default_value_t = false)]
    pub restart: bool,
    ///The directory of the project
    #[arg(short, long, default_value_t=String::from(DEFAULT_PROJECT_ROOT_PATH))]
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
    #[arg(short, long, default_value_t=String::from(DEFAULT_PROJECT_ROOT_PATH))]
    pub directory: String,

    ///The directory within the project that generated code should output to
    #[arg(short, long, default_value_t=String::from(DEFAULT_GENERATED_PATH))]
    pub output_directory: String,

    ///The file in the project containing config.
    #[arg(short, long, default_value_t=String::from(DEFAULT_CONFIG_PATH))]
    pub config: String,
}

#[derive(Args, Debug)]
pub struct InitArgs {
    ///The directory of the project
    #[arg(short, long, default_value_t=String::from(DEFAULT_PROJECT_ROOT_PATH))]
    pub directory: String,

    ///The file in the project containing config.
    #[arg(short, long)]
    #[clap(value_enum)]
    pub template: Option<Template>,
    #[arg(short = 'l', long = "language")]
    #[clap(value_enum)]
    pub language: Option<Language>,
}

#[derive(Clone, Debug, ValueEnum, Serialize, Deserialize)]
///Template to work off
pub enum Template {
    Blank,
    Greeter,
    Erc20,
    SubgraphMigrationExperimental,
}

#[derive(Clone, Debug, ValueEnum, Serialize, Deserialize)]
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
            project_root: DEFAULT_PROJECT_ROOT_PATH.to_string(),
            generated: DEFAULT_GENERATED_PATH.to_string(),
            config: DEFAULT_CONFIG_PATH.to_string(),
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

impl ToProjectPathsArgs for InitArgs {
    fn to_project_paths_args(&self) -> ProjectPathsArgs {
        ProjectPathsArgs {
            project_root: self.directory.clone(),
            generated: DEFAULT_GENERATED_PATH.to_string(),
            config: DEFAULT_CONFIG_PATH.to_string(),
        }
    }
}
impl ToProjectPathsArgs for StartArgs {
    fn to_project_paths_args(&self) -> ProjectPathsArgs {
        ProjectPathsArgs {
            project_root: self.directory.clone(),
            generated: DEFAULT_GENERATED_PATH.to_string(),
            config: DEFAULT_CONFIG_PATH.to_string(),
        }
    }
}
