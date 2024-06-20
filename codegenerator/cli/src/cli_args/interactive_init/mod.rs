mod evm_prompts;
mod fuel_prompts;
mod inquire_helpers;
mod shared_prompts;
pub mod validation;

use super::{
    clap_definitions::{self, InitArgs, ProjectPaths},
    init_config::{InitConfig, Language},
};
use crate::constants::project_paths::DEFAULT_PROJECT_ROOT_PATH;
use anyhow::{Context, Result};
use inquire::{Select, Text};
use std::str::FromStr;
use strum::IntoEnumIterator;
use validation::{
    contains_no_whitespace_validator, is_directory_new_validator, is_not_empty_string_validator,
    is_valid_foldername_inquire_validator,
};

pub async fn prompt_missing_init_args(
    init_args: InitArgs,
    project_paths: &ProjectPaths,
) -> Result<InitConfig> {
    let name: String = match init_args.name {
        Some(args_name) => args_name,
        None => {
            // TODO: input validation for name
            Text::new("Name your indexer:")
                .with_default("My Envio Indexer")
                .with_validator(is_not_empty_string_validator)
                .prompt()?
        }
    };

    let directory: String = match &project_paths.directory {
        Some(args_directory) => args_directory.clone(),
        None => {
            Text::new("Specify a folder name (ENTER to skip): ")
                .with_default(DEFAULT_PROJECT_ROOT_PATH)
                // validate string is valid directory name
                .with_validator(is_valid_foldername_inquire_validator)
                // validate the directory doesn't already exist
                .with_validator(is_directory_new_validator)
                .with_validator(contains_no_whitespace_validator)
                .prompt()?
        }
    };

    let language = match init_args.language {
        Some(args_language) => args_language,
        None => {
            let options = Language::iter()
                .map(|language| language.to_string())
                .collect::<Vec<String>>();

            let input_language = Select::new("Which language would you like to use?", options)
                .with_starting_cursor(1)
                .prompt()
                .context("prompting user to select language")?;

            Language::from_str(&input_language)
                .context("parsing user input for language selection")?
        }
    };

    let ecosystem = shared_prompts::prompt_ecosystem(init_args.init_commands)
        .await
        .context("Failed getting template")?;

    Ok(InitConfig {
        name,
        directory,
        ecosystem,
        language,
    })
}
