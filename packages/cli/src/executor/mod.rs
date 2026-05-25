use crate::{
    clap_definitions::{ConfigSubcommand, JsonSchema, Script, SkillsSubcommand},
    cli_args::clap_definitions::{CommandLineArgs, CommandType},
    commands,
    config_parsing::{human_config, system_config::SystemConfig},
    docker_env,
    project_paths::ParsedProjectPaths,
    scripts,
};

mod codegen;
mod config;
mod dev;
pub mod init;
mod local;
mod metrics;
mod skills;

use anyhow::{Context, Result};
use schemars::schema_for;

/// A deferred work item the executor asks its host to run after Rust returns.
/// Anything that must run in the JS event loop — migrations, indexer start,
/// anything that loads `envio/src/*.res.mjs` — is encoded as a `Command`.
///
/// Wire format: serde-tagged JSON on the `kind` field.
#[derive(Debug, Clone, serde::Serialize)]
#[serde(tag = "kind", rename_all = "kebab-case")]
pub enum Command {
    /// `reset: true` wipes the schema before the indexer's first init call;
    /// the runtime always runs `Persistence.init` either way (DB compat and
    /// migration decisions live in ReScript now).
    Start {
        reset: bool,
        cwd: String,
        env: serde_json::Map<String, serde_json::Value>,
        config: serde_json::Value,
    },
    Migrate {
        reset: bool,
        config: serde_json::Value,
    },
    DropSchema {
        config: serde_json::Value,
    },
}

/// `envio_package_dir` is only consumed by `get_envio_version` on dev builds
/// (to stamp the `envio` `file:{dir}` dep into generated / init
/// `package.json`s). Commands that don't call it — `script` subcommands —
/// may pass `None`; init/codegen/dev/start on a dev build without it will
/// error out of `get_envio_version`.
///
/// Returns `None` for commands that finish entirely in Rust. The NAPI shim
/// forwards that to JS as `null` so the host exits cleanly.
pub async fn execute(
    command_line_args: CommandLineArgs,
    envio_package_dir: Option<&str>,
) -> Result<Option<Command>> {
    let global_project_paths = command_line_args.project_paths;
    let parsed_project_paths = ParsedProjectPaths::try_from(global_project_paths.clone())
        .context("Failed parsing project paths")?;

    match command_line_args.command {
        CommandType::Init(init_args) => {
            init::run_init_args(init_args, &global_project_paths, envio_package_dir).await?;
            Ok(None)
        }

        CommandType::Codegen => {
            codegen::run_codegen(&parsed_project_paths).await?;
            Ok(None)
        }

        CommandType::Dev(dev_args) => Ok(Some(
            dev::run_dev(parsed_project_paths, dev_args.restart).await?,
        )),

        CommandType::Stop => {
            docker_env::down().await?;
            Ok(None)
        }

        CommandType::Metrics => {
            metrics::run().await?;
            Ok(None)
        }

        CommandType::Skills(SkillsSubcommand::Update) => {
            skills::run_update(&parsed_project_paths)?;
            Ok(None)
        }

        CommandType::Config(ConfigSubcommand::View) => {
            config::run_view(&parsed_project_paths)?;
            Ok(None)
        }

        CommandType::Start(start_args) => {
            let config = SystemConfig::parse_from_project_files(&parsed_project_paths)
                .context("Failed parsing config")?;

            // Always regenerate so the runtime never boots against stale
            // codegen output (e.g. after an `envio` package upgrade).
            // Mirrors `envio dev`; the JS side handles DB compat via
            // `envio_info`.
            commands::codegen::run_codegen(&config)
                .await
                .context("Failed running codegen")?;

            // `envio start` doesn't manage Docker — users are expected to
            // have their own services and env vars set up (e.g. via .env).
            Ok(Some(build_start_command(
                &config,
                start_args.restart,
                false,
                &[],
            )?))
        }

        CommandType::Local(local_commands) => {
            Ok(local::run_local(&local_commands, &parsed_project_paths).await?)
        }

        CommandType::Script(Script::PrintCliHelpMd) => {
            println!("{}", CommandLineArgs::generate_markdown_help());
            Ok(None)
        }
        CommandType::Script(Script::PrintConfigJsonSchema(json_schema)) => {
            match json_schema {
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
                JsonSchema::Svm => {
                    let schema = schema_for!(human_config::svm::HumanConfig);
                    println!(
                        "{}",
                        serde_json::to_string_pretty(&schema)
                            .context("Failed serializing svm json schema")?
                    );
                }
            };
            Ok(None)
        }
        CommandType::Script(Script::PrintMissingNetworks) => {
            scripts::print_missing_networks::run()
                .await
                .context("Failed print missing networks script")?;
            Ok(None)
        }
    }
}

/// `ENVIO_CONFIG` is always present in the returned `env`; callers may
/// append extra env pairs (e.g. ClickHouse credentials from Docker for
/// `envio dev`).
pub fn build_start_command(
    config: &SystemConfig,
    reset: bool,
    is_dev: bool,
    extra_env: &[(String, String)],
) -> Result<Command> {
    let config_path = config
        .parsed_project_paths
        .config
        .to_string_lossy()
        .into_owned();

    let env: serde_json::Map<String, serde_json::Value> =
        std::iter::once(("ENVIO_CONFIG".to_string(), config_path.into()))
            .chain(extra_env.iter().map(|(k, v)| (k.clone(), v.clone().into())))
            .collect();

    Ok(Command::Start {
        reset,
        cwd: config
            .parsed_project_paths
            .project_root
            .to_string_lossy()
            .into_owned(),
        env,
        config: public_config_value(config, is_dev)?,
    })
}

/// Returns a `Value` (not a string) so the serde payload embeds the config
/// as a nested JSON object — the JS side then skips the extra `JSON.parse`.
pub fn public_config_value(config: &SystemConfig, is_dev: bool) -> Result<serde_json::Value> {
    serde_json::from_str(&config.to_public_config_json(is_dev)?)
        .context("Failed parsing public config JSON")
}
