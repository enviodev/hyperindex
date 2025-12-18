use crate::{
    clap_definitions::{ConfigSubcommands, JsonSchema, Script},
    cli_args::clap_definitions::{CommandLineArgs, CommandType},
    commands,
    config_parsing::{human_config, system_config::SystemConfig},
    persisted_state::{PersistedState, PersistedStateExists, CURRENT_CRATE_VERSION},
    project_paths::ParsedProjectPaths,
    scripts,
};

mod codegen;
mod dev;
pub mod init;
mod local;

use anyhow::{Context, Result};
use schemars::schema_for;

pub async fn execute(command_line_args: CommandLineArgs) -> Result<()> {
    let global_project_paths = command_line_args.project_paths;
    let parsed_project_paths = ParsedProjectPaths::try_from(global_project_paths.clone())
        .context("Failed parsing project paths")?;

    match command_line_args.command {
        CommandType::Init(init_args) => {
            init::run_init_args(init_args, &global_project_paths).await?;
        }

        CommandType::Codegen => {
            codegen::run_codegen(&parsed_project_paths).await?;
        }

        CommandType::Dev => {
            dev::run_dev(parsed_project_paths).await?;
        }

        CommandType::Stop => {
            let config = SystemConfig::parse_from_project_files(&parsed_project_paths)
                .context("Failed parsing config")?;
            commands::docker::docker_compose_down_v(&config).await?;
        }

        CommandType::Start(start_args) => {
            //Add warnings to start command
            match PersistedStateExists::get_persisted_state_file(&parsed_project_paths) {
                PersistedStateExists::Exists(ps) if ps.envio_version != CURRENT_CRATE_VERSION => {
                    println!(
                        "WARNING: Envio version '{}' is currently being used. It does not match \
                         the version '{}' that was used to create generated directory previously. \
                         Please consider rerunning envio codegen, or running the same version of \
                         envio. ",
                        CURRENT_CRATE_VERSION, &ps.envio_version
                    )
                }
                PersistedStateExists::NotExists => println!(
                    "WARNING: Generated directory not detected. Consider running envio codegen \
                     first"
                ),
                PersistedStateExists::Corrupted => println!(
                    "WARNING: Generated directory is corrupted. Consider running envio codegen \
                     first"
                ),
                PersistedStateExists::Exists(_) => (),
            };

            if start_args.bench {
                std::env::set_var("ENVIO_SAVE_BENCHMARK_DATA", "true");
            }

            let config = SystemConfig::parse_from_project_files(&parsed_project_paths)
                .context("Failed parsing config")?;

            if start_args.restart {
                let persisted_state = PersistedState::get_current_state(&config)
                    .context("Failed constructing persisted state")?;

                commands::db_migrate::run_db_setup(&config, &persisted_state).await?;
            }
            const SHOULD_OPEN_HASURA: bool = false;
            commands::start::start_indexer(&config, SHOULD_OPEN_HASURA).await?;
        }

        CommandType::Local(local_commands) => {
            local::run_local(&local_commands, &parsed_project_paths).await?;
        }

        CommandType::BenchmarkSummary => {
            let config = SystemConfig::parse_from_project_files(&parsed_project_paths)
                .context("Failed parsing config")?;
            commands::benchmark::print_summary(&config).await?
        }

        CommandType::Script(Script::PrintCliHelpMd) => {
            println!("{}", CommandLineArgs::generate_markdown_help());
        }
        CommandType::Script(Script::PrintConfigJsonSchema(json_schema)) => match json_schema {
            JsonSchema::Evm => {
                let schema = schema_for!(human_config::evm::HumanConfig);
                println!(
                    "{}",
                    serde_json::to_string_pretty(&schema)
                        .context("Failed serializing evm json schema")?
                );
            }
            JsonSchema::Fuel => {
                let schema = schema_for!(human_config::fuel::HumanConfig);
                println!(
                    "{}",
                    serde_json::to_string_pretty(&schema)
                        .context("Failed serializing fuel json schema")?
                );
            }
            JsonSchema::Solana => {
                let schema = schema_for!(human_config::solana::HumanConfig);
                println!(
                    "{}",
                    serde_json::to_string_pretty(&schema)
                        .context("Failed serializing solana json schema")?
                );
            }
        },
        CommandType::Script(Script::PrintMissingNetworks) => {
            scripts::print_missing_networks::run()
                .await
                .context("Failed print missing networks script")?;
        }

        CommandType::Config(config_cmd) => match config_cmd {
            ConfigSubcommands::List => {
                let config = SystemConfig::parse_from_project_files(&parsed_project_paths)
                    .context("Failed parsing config")?;
                let base_config = config.human_config.get_base_config();
                let json_config =
                    human_config::BaseConfigJson::new(base_config, CURRENT_CRATE_VERSION);
                println!(
                    "{}",
                    serde_json::to_string_pretty(&json_config)
                        .context("Failed serializing config to JSON")?
                );
            }
        },
    };

    Ok(())
}

#[cfg(test)]
mod tests {
    use crate::config_parsing::human_config::{evm::HumanConfig, BaseConfig, BaseConfigJson};
    use pretty_assertions::assert_eq;
    use serde_json::json;
    use std::path::PathBuf;

    const TEST_VERSION: &str = "1.0.0";

    #[test]
    fn test_config_list_outputs_camel_case_json() {
        let config_path =
            PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("test/configs/config1.yaml");

        let file_str = std::fs::read_to_string(config_path).expect("Failed to read config file");
        let config: HumanConfig = serde_yaml::from_str(&file_str).expect("Failed to parse config");

        let json_config = BaseConfigJson::new(&config.base, TEST_VERSION);
        let json_output: serde_json::Value =
            serde_json::to_value(&json_config).expect("Failed to serialize to JSON");

        assert_eq!(
            json_output,
            json!({
                "version": TEST_VERSION,
                "name": "config1",
                "description": "Gravatar for Ethereum",
                "schema": "../schemas/schema.graphql"
            })
        );
    }

    #[test]
    fn test_config_list_omits_null_fields() {
        let config_path =
            PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("test/configs/fuel-config.yaml");

        let file_str = std::fs::read_to_string(config_path).expect("Failed to read config file");
        let config: crate::config_parsing::human_config::fuel::HumanConfig =
            serde_yaml::from_str(&file_str).expect("Failed to parse config");

        let json_config = BaseConfigJson::new(&config.base, TEST_VERSION);
        let json_output: serde_json::Value =
            serde_json::to_value(&json_config).expect("Failed to serialize to JSON");

        assert_eq!(
            json_output,
            json!({
                "version": TEST_VERSION,
                "name": "Fuel indexer"
            })
        );
    }

    #[test]
    fn test_config_list_full_batch_size_camel_case() {
        let base_config = BaseConfig {
            name: "test-indexer".to_string(),
            description: Some("Test description".to_string()),
            schema: None,
            output: None,
            handlers: None,
            full_batch_size: Some(10000),
        };

        let json_config = BaseConfigJson::new(&base_config, TEST_VERSION);
        let json_output: serde_json::Value =
            serde_json::to_value(&json_config).expect("Failed to serialize to JSON");

        assert_eq!(
            json_output,
            json!({
                "version": TEST_VERSION,
                "name": "test-indexer",
                "description": "Test description",
                "fullBatchSize": 10000
            })
        );
    }
}
