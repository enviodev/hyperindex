use clap::{Args, Parser, Subcommand, ValueEnum};

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
}

#[derive(Args, Debug)]
pub struct CodegenArgs {
    ///The directory of the project
    #[arg(short, long, default_value_t=String::from("./"))]
    pub directory: String,

    ///The directory within the project that generated code should output to
    #[arg(short, long, default_value_t=String::from("generated/"))]
    pub output_directory: String,

    ///The file in the project containing config.
    #[arg(short, long, default_value_t=String::from("config.yaml"))]
    pub config: String,
}

#[derive(Args, Debug)]
pub struct InitArgs {
    ///The directory of the project
    #[arg(short, long, default_value_t=String::from("./"))]
    pub directory: String,

    ///The file in the project containing config.
    #[arg(short, long, default_value_t=Template::Gravatar)]
    #[clap(value_enum)]
    pub template: Template,
}

#[derive(Clone, Debug, ValueEnum)]
///Template to work off
pub enum Template {
    Gravatar,
}
