use crate::{
    clap_definitions::{JsonSchema, Script},
    cli_args::clap_definitions::{CommandLineArgs, CommandType},
    config_parsing::{human_config, system_config::SystemConfig},
    docker_env,
    persisted_state::{self, PersistedState, PersistedStateExists},
    project_paths::ParsedProjectPaths,
    scripts,
};

mod codegen;
mod dev;
pub mod init;
mod local;

use anyhow::{Context, Result};
use schemars::schema_for;

/// A deferred work item the executor asks its host to run after Rust returns.
///
/// Rust handles config parsing, codegen, docker, persisted state — everything
/// that doesn't need JS. Work that must run in the JS event loop (migrations,
/// indexer start — anything that loads `envio/src/*.res.mjs` modules) is
/// returned as a `Command`. The CLI layer knows nothing about how the host
/// dispatches it: the NAPI shim forwards it to JS, a test harness could
/// run it inline, a future standalone binary could spawn a Node subprocess,
/// etc.
///
/// Wire format: serde-tagged JSON on the `kind` field.
#[derive(Debug, Clone, serde::Serialize)]
#[serde(tag = "kind", rename_all = "kebab-case")]
pub enum Command {
    /// Run the indexer. If `migrate` is `Some`, also run the migration as
    /// part of the same persistence initialization (single `init()` call).
    Start {
        migrate: Option<MigrateOpts>,
        cwd: String,
        env: serde_json::Map<String, serde_json::Value>,
        config: serde_json::Value,
    },
    /// Run migrations without starting the indexer (`local db up`, `local db setup`).
    Migrate {
        reset: bool,
        #[serde(rename = "persistedState")]
        persisted_state: PersistedState,
        config: serde_json::Value,
    },
    /// Drop the schema (`local db down`).
    DropSchema { config: serde_json::Value },
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct MigrateOpts {
    pub reset: bool,
    #[serde(rename = "persistedState")]
    pub persisted_state: PersistedState,
}

/// `envio_package_dir` is the absolute path of the running envio JS package
/// when this executor is invoked via NAPI (the JS host resolves it from
/// `import.meta.url`). Used only to stamp the `envio` `file:{dir}` dep
/// into generated / init project `package.json`s for dev builds. `None`
/// is fine for commands that don't call `get_envio_version` (e.g.
/// `script` subcommands); init/codegen/dev/start on a dev build without
/// it will error out of `get_envio_version`.
///
/// Returns `None` for commands that finish entirely in Rust (codegen, init,
/// stop, docker up/down, help/version, scripts). The NAPI shim maps `None`
/// to a JS `null`, signalling the JS host to exit cleanly.
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
            codegen::run_codegen(&parsed_project_paths, envio_package_dir).await?;
            Ok(None)
        }

        CommandType::Dev(dev_args) => Ok(Some(
            dev::run_dev(parsed_project_paths, dev_args.restart, envio_package_dir).await?,
        )),

        CommandType::Stop => {
            docker_env::down().await?;
            Ok(None)
        }

        CommandType::Start(start_args) => {
            //Add warnings to start command
            match PersistedStateExists::get_persisted_state_file(&parsed_project_paths) {
                PersistedStateExists::Exists(ps)
                    if ps.envio_version != persisted_state::current_version() =>
                {
                    println!(
                        "WARNING: Envio version '{}' is currently being used. It does not match \
                         the version '{}' that was used to create generated directory previously. \
                         Please consider rerunning envio codegen, or running the same version of \
                         envio. ",
                        persisted_state::current_version(),
                        &ps.envio_version
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

            let config = SystemConfig::parse_from_project_files(&parsed_project_paths)
                .context("Failed parsing config")?;

            let migrate = if start_args.restart {
                let persisted_state = PersistedState::get_current_state(&config)
                    .context("Failed constructing persisted state")?;
                Some(MigrateOpts {
                    reset: true,
                    persisted_state,
                })
            } else {
                None
            };

            // `envio start` doesn't manage Docker — users are expected to
            // have their own services and env vars set up (e.g. via .env).
            Ok(Some(build_start_command(&config, migrate, &[])?))
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

/// Build a `Start` command payload. The indexer's entry is `Main.start` in the
/// envio runtime — Bin.res calls it directly, so Rust no longer computes an
/// indexer module path. `ENVIO_CONFIG` is always present in `env`; callers may
/// append extra env pairs (e.g. `ENVIO_DEV_MODE` for `envio dev`).
pub fn build_start_command(
    config: &SystemConfig,
    migrate: Option<MigrateOpts>,
    extra_env: &[(String, String)],
) -> Result<Command> {
    let config_path = config
        .parsed_project_paths
        .config
        .to_string_lossy()
        .into_owned();

    let mut env_map = serde_json::Map::new();
    env_map.insert("ENVIO_CONFIG".to_string(), config_path.into());
    for (k, v) in extra_env {
        env_map.insert(k.clone(), v.clone().into());
    }

    Ok(Command::Start {
        migrate,
        cwd: config
            .parsed_project_paths
            .project_root
            .to_string_lossy()
            .into_owned(),
        env: env_map,
        config: public_config_value(config)?,
    })
}

/// Parse the config JSON (a string) into a `serde_json::Value` so it
/// serializes as a nested JSON object in the command payload. Bin.res then
/// passes it to `Config.prime` without an extra `JSON.parse`.
pub fn public_config_value(config: &SystemConfig) -> Result<serde_json::Value> {
    serde_json::from_str(&config.to_public_config_json()?)
        .context("Failed parsing public config JSON")
}
