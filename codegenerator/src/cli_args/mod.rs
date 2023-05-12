use clap::{Args, Parser, Subcommand, ValueEnum};
use serde::{Deserialize, Serialize};
pub mod interactive_init;

#[derive(Debug, Parser)]
#[clap(author, version, about)]
pub struct CommandLineArgs {
    #[clap(subcommand)]
    pub command: CommandType,
}

#[derive(Debug, Subcommand)]
pub enum CommandType {
    ///Generate code from a config.yaml file
    Codegen(CodegenArgs),

    ///Initialize a project with a template
    Init(InitArgs),

    ///Print help into a markdown file
    ///Command to run: cargo run -- print-all-help --markdown > CommandLineHelp.md
    #[clap(hide = true)]
	PrintAllHelp {
		#[clap(long, required = true)]
		markdown: bool,
	},
}

pub const DEFAULT_PROJECT_ROOT_PATH: &str = "./";
pub const DEFAULT_GENERATED_PATH: &str = "generated/";
pub const DEFAULT_CONFIG_PATH: &str = "config.yaml";

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
    #[arg(short = 'f', long = "js-flavor")]
    #[clap(value_enum)]
    pub js_flavor: Option<JsFlavor>,
}

#[derive(Clone, Debug, ValueEnum, Serialize, Deserialize)]
///Template to work off
pub enum Template {
    Gravatar,
}

#[derive(Clone, Debug, ValueEnum, Serialize, Deserialize)]
///Which js flavor do you want to write in?
pub enum JsFlavor {
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
