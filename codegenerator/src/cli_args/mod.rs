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

    ///Generate code from a config.yaml file
    Codegen(CodegenArgs),

    ///Prepare local environment for envio testing
    #[command(subcommand)]
    Local(LocalCommandTypes),

    ///Print help into a markdown file
    ///Command to run: cargo run -- print-all-help > CommandLineHelp.md
    #[clap(hide = true)]
    PrintAllHelp,
}

#[derive(Debug, Subcommand)]
pub enum LocalCommandTypes {
    /// Local Envio and ganache environment commands
    #[command(subcommand)]
    Docker(LocalDockerArgs),
    /// Local Envio database commands
    #[command(subcommand)]
    DbMigrate(DbMigrateArgs),
}

#[derive(Clone, Debug, Subcommand)]
pub enum LocalDockerArgs {
    ///Create a docker container for ganache and postgres
    Up,
    ///Shut down docker container for ganache and postgres
    Down,
}

#[derive(Clone, Debug, Subcommand)]
pub enum DbMigrateArgs {
    ///Migrate latest schema to database
    Up,
    ///Drop database schema
    Down,
    ///Setup database by dropping schema and running up migrations
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
    Erc20,
    Greeter,
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

impl ToProjectPathsArgs for LocalDockerArgs {
    fn to_project_paths_args(&self) -> ProjectPathsArgs {
        ProjectPathsArgs {
            project_root: DEFAULT_PROJECT_ROOT_PATH.to_string(),
            generated: DEFAULT_GENERATED_PATH.to_string(),
            config: DEFAULT_CONFIG_PATH.to_string(),
        }
    }
}
impl ToProjectPathsArgs for DbMigrateArgs {
    fn to_project_paths_args(&self) -> ProjectPathsArgs {
        ProjectPathsArgs {
            project_root: DEFAULT_PROJECT_ROOT_PATH.to_string(),
            generated: DEFAULT_GENERATED_PATH.to_string(),
            config: DEFAULT_CONFIG_PATH.to_string(),
        }
    }
}
