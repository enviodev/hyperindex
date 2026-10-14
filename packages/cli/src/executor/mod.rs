use crate::{
    clap_definitions::{ConfigSubcommand, JsonSchema, MetricsSubcommand, Script, SkillsSubcommand},
    cli_args::clap_definitions::{CommandLineArgs, CommandType, ProjectPaths},
    commands,
    config_parsing::{human_config, system_config::SystemConfig},
    constants::project_paths::DEFAULT_CONFIG_PATH,
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
mod tools;

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
    Sidecar {
        cwd: String,
        env: serde_json::Map<String, serde_json::Value>,
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
    let project_flags = project_flags(&command_line_args.project_paths);
    let command = execute_command(command_line_args, envio_package_dir).await?;
    Ok(command.map(|command| command.with_project_flags(project_flags)))
}

/// The flags the operator gave to find the project, which every command the
/// runtime prints for them to run next has to repeat.
fn project_flags(project_paths: &ProjectPaths) -> String {
    let directory = project_paths
        .directory
        .iter()
        .map(|directory| format!("-d {directory}"));
    let config = (project_paths.config != DEFAULT_CONFIG_PATH)
        .then(|| format!("--config {}", project_paths.config));
    directory.chain(config).collect::<Vec<_>>().join(" ")
}

impl Command {
    fn with_project_flags(mut self, project_flags: String) -> Self {
        if !project_flags.is_empty() {
            let (Command::Start { config, .. }
            | Command::Migrate { config, .. }
            | Command::DropSchema { config }
            | Command::Sidecar { config, .. }) = &mut self;
            config["projectFlags"] = project_flags.into();
        }
        self
    }
}

/// Envio Cloud runs `envio sidecar` with no flags from the image directory and
/// names the tenant's config file only in `CONFIG_FILE`, so a sidecar there
/// would otherwise look for a `config.yaml` that may not exist. Only clap's
/// default gives way: a `--config` or `ENVIO_CONFIG`, even `config.yaml`,
/// always wins, which only the matches can tell apart from the default.
pub fn use_hosted_sidecar_config_file(
    command_line_args: &mut CommandLineArgs,
    matches: &clap::ArgMatches,
    config_file_env: Option<&str>,
) {
    let config_is_default =
        matches.value_source("config") == Some(clap::parser::ValueSource::DefaultValue);
    match (&command_line_args.command, config_file_env) {
        (CommandType::Sidecar, Some(config_file))
            if config_is_default && !config_file.is_empty() =>
        {
            command_line_args.project_paths.config = config_file.to_string();
        }
        _ => (),
    }
}

async fn execute_command(
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

        CommandType::Metrics(metrics_args) => {
            let runtime = matches!(metrics_args.subcommand, Some(MetricsSubcommand::Runtime));
            metrics::run(runtime, &parsed_project_paths.project_root).await?;
            Ok(None)
        }

        CommandType::Skills(SkillsSubcommand::Update) => {
            skills::run_update(&parsed_project_paths)?;
            Ok(None)
        }

        CommandType::Tools(tools_subcommand) => {
            tools::run(tools_subcommand).await?;
            Ok(None)
        }

        CommandType::Config(ConfigSubcommand::View) => {
            config::run_view(&parsed_project_paths)?;
            Ok(None)
        }

        CommandType::Start(start_args) => {
            let config = SystemConfig::parse_from_project_files(&parsed_project_paths)
                .context("Failed parsing config")?;

            // Before codegen, so a mistyped `--chain` fails in the moment rather
            // than after a full regeneration.
            validate_chain_selection(&config, &start_args.chains, start_args.restart)?;

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
                &start_args.chains,
            )?))
        }

        // No codegen: the sidecar runs from a build that already happened, and in
        // Envio Cloud it shares the image with the indexer container.
        CommandType::Sidecar => {
            let config = SystemConfig::parse_from_project_files(&parsed_project_paths)
                .context("Failed parsing config")?;
            if config.human_config.get_base_config().sidecar.is_none() {
                anyhow::bail!(
                    "`envio sidecar` has nothing to run: {} has no `sidecar:` key. Add \
                     `sidecar: {{ contract: src/sidecar/contract.ts, entry: src/sidecar/index.ts }}`.",
                    config.parsed_project_paths.config_relative_to_root().display()
                );
            }
            Ok(Some(build_sidecar_command(&config)?))
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
///
/// `ENVIO_CONFIG` is root-relative: consumers resolve it against
/// `cwd` / `--directory`, so a cwd-joined value would double the prefix.
pub fn build_start_command(
    config: &SystemConfig,
    reset: bool,
    is_dev: bool,
    extra_env: &[(String, String)],
    // `--chain`: rides in the public config as `isolatedChains`, next to
    // `isDev`, so the runtime reads the selection off the config it already
    // parses. Empty means every chain, which is what a run without the flag does.
    chains: &[u64],
) -> Result<Command> {
    let config_path = config
        .parsed_project_paths
        .config_relative_to_root()
        .to_string_lossy()
        .into_owned();

    let env: serde_json::Map<String, serde_json::Value> =
        std::iter::once(("ENVIO_CONFIG".to_string(), config_path.into()))
            .chain(extra_env.iter().map(|(k, v)| (k.clone(), v.clone().into())))
            .collect();

    let mut public_config = public_config_value(config, is_dev)?;
    if !chains.is_empty() {
        public_config["isolatedChains"] = chains.iter().copied().collect();
    }

    Ok(Command::Start {
        reset,
        cwd: config
            .parsed_project_paths
            .project_root
            .to_string_lossy()
            .into_owned(),
        env,
        config: public_config,
    })
}

fn build_sidecar_command(config: &SystemConfig) -> Result<Command> {
    let config_path = config
        .parsed_project_paths
        .config_relative_to_root()
        .to_string_lossy()
        .into_owned();
    Ok(Command::Sidecar {
        cwd: config
            .parsed_project_paths
            .project_root
            .to_string_lossy()
            .into_owned(),
        env: std::iter::once(("ENVIO_CONFIG".to_string(), config_path.into())).collect(),
        config: public_config_value(config, false)?,
    })
}

/// `--chain` splits one schema's chains across processes. Two things have to
/// hold, and both are cheaper to reject here than to discover at runtime: every
/// id has to name a configured chain, and no entity may be shared across chains,
/// since separate processes each advance their own checkpoint sequence.
fn validate_chain_selection(config: &SystemConfig, chains: &[u64], restart: bool) -> Result<()> {
    if chains.is_empty() {
        return Ok(());
    }

    // Clap could reject this as a conflict, but the generic message wouldn't say
    // what to do instead, and a reset is the one thing a `--chain` process can't
    // do for itself: it would wipe the chains other processes are driving.
    if restart {
        anyhow::bail!(
            "`envio start --chain` can't restart from scratch, because the database it clears \
             holds the chains other processes are driving. Stop every chain's process, run \
             `envio local db-migrate setup` once with the full config, then start them again."
        );
    }

    let mut shared: Vec<&str> = config
        .schema
        .entities
        .values()
        .filter(|entity| entity.is_cross_chain(config.default_chain_scope))
        .map(|entity| entity.name.as_str())
        .collect();
    if !shared.is_empty() {
        shared.sort_unstable();
        // Naming all of them is only useful when some are per-chain. Without
        // `disable_default_cross_chain` every entity is shared, and the list is
        // just the schema read back.
        let remedy = if shared.len() == config.schema.entities.len() {
            "Every entity in this schema is cross-chain, because config.yaml doesn't set \
             `disable_default_cross_chain: true`. Set it, then run every chain in its own process."
                .to_string()
        } else {
            format!(
                "Entities shared across chains: {}. Drop `@crossChain` from them, or run every \
                 chain in one process.",
                shared.join(", ")
            )
        };
        anyhow::bail!(
            "`envio start --chain` needs every entity to be per-chain, because chains indexed in \
             separate processes can't share a checkpoint sequence. {remedy}"
        );
    }

    for chain in chains {
        if !config.chains.contains_key(chain) {
            let mut configured: Vec<u64> = config.chains.keys().copied().collect();
            configured.sort_unstable();
            anyhow::bail!(
                "Chain {chain} is not configured, so `envio start --chain {chain}` has nothing to \
                 index. Configured chains: {}.",
                configured
                    .iter()
                    .map(|id| id.to_string())
                    .collect::<Vec<_>>()
                    .join(", ")
            );
        }
    }

    Ok(())
}

/// Returns a `Value` (not a string) so the serde payload embeds the config
/// as a nested JSON object — the JS side then skips the extra `JSON.parse`.
pub fn public_config_value(config: &SystemConfig, is_dev: bool) -> Result<serde_json::Value> {
    serde_json::from_str(&config.to_public_config_json(is_dev)?)
        .context("Failed parsing public config JSON")
}

#[cfg(test)]
mod chain_selection_tests {
    use super::validate_chain_selection;
    use crate::config_parsing::system_config::SystemConfig;
    use std::collections::HashMap;

    const PER_CHAIN_SCHEMA: &str = r#"
type Counter {
  id: ID!
  count: BigInt!
}
"#;

    fn config(disable_default_cross_chain: bool) -> SystemConfig {
        let yaml = format!(
            r#"
name: chain-selection
{}
contracts:
  - name: Counters
    events:
      - event: Bumped(uint256 amount)
chains:
  - id: 1
    start_block: 0
    contracts:
      - name: Counters
        address: "0x1111111111111111111111111111111111111111"
  - id: 137
    start_block: 0
    contracts:
      - name: Counters
        address: "0x2222222222222222222222222222222222222222"
"#,
            if disable_default_cross_chain {
                "disable_default_cross_chain: true"
            } else {
                ""
            }
        );
        // The same schema either way: without the flag every entity is
        // cross-chain by default, which is the case `--chain` has to reject.
        SystemConfig::parse_yaml(
            &yaml,
            Some(PER_CHAIN_SCHEMA),
            &HashMap::new(),
            &HashMap::new(),
            false,
        )
        .expect("config should parse")
    }

    #[test]
    fn accepts_configured_chains_of_a_per_chain_schema() {
        let config = config(true);
        assert_eq!(
            (
                validate_chain_selection(&config, &[137], false).is_ok(),
                validate_chain_selection(&config, &[1, 137], false).is_ok(),
            ),
            (true, true)
        );
    }

    #[test]
    fn accepts_a_run_without_the_flag_whatever_the_schema() {
        assert!(validate_chain_selection(&config(false), &[], false).is_ok());
    }

    #[test]
    fn rejects_a_restart_and_says_what_to_do_instead() {
        let err = validate_chain_selection(&config(true), &[1], true)
            .expect_err("a restart under --chain should be rejected");
        assert_eq!(
            err.to_string(),
            "`envio start --chain` can't restart from scratch, because the database it clears \
             holds the chains other processes are driving. Stop every chain's process, run \
             `envio local db-migrate setup` once with the full config, then start them again."
        );
    }

    #[test]
    fn rejects_a_chain_the_config_does_not_declare() {
        let err = validate_chain_selection(&config(true), &[42], false)
            .expect_err("an unconfigured chain should be rejected");
        assert_eq!(
            err.to_string(),
            "Chain 42 is not configured, so `envio start --chain 42` has nothing to index. \
             Configured chains: 1, 137."
        );
    }

    #[test]
    fn rejects_a_schema_that_shares_entities_across_chains() {
        let err = validate_chain_selection(&config(false), &[1], false)
            .expect_err("a cross-chain schema should be rejected");
        assert_eq!(
            err.to_string(),
            "`envio start --chain` needs every entity to be per-chain, because chains indexed in \
             separate processes can't share a checkpoint sequence. Every entity in this schema is \
             cross-chain, because config.yaml doesn't set `disable_default_cross_chain: true`. Set \
             it, then run every chain in its own process."
        );
    }
}

#[cfg(test)]
mod project_flags_tests {
    use super::{execute, Command};
    use crate::cli_args::clap_definitions::CommandLineArgs;
    use clap::Parser;

    async fn project_flags(args: &[&str]) -> serde_json::Value {
        let command = execute(CommandLineArgs::parse_from(args), None)
            .await
            .expect("the command should run")
            .expect("the command should hand work to the runtime");
        match command {
            Command::Migrate { config, .. } => config["projectFlags"].clone(),
            other => panic!("expected a migration, got {other:?}"),
        }
    }

    // The runtime prints commands for the operator to run next, and they have to
    // find the same project the operator's own command did.
    #[tokio::test]
    async fn carries_the_flags_that_locate_the_project() {
        let directory = format!("{}/../../scenarios/split_test", env!("CARGO_MANIFEST_DIR"));
        assert_eq!(
            (
                project_flags(&["envio", "local", "db-migrate", "up", "-d", &directory]).await,
                project_flags(&[
                    "envio",
                    "local",
                    "db-migrate",
                    "up",
                    "-d",
                    &directory,
                    "--config",
                    "config.head.yaml",
                ])
                .await,
            ),
            (
                serde_json::json!(format!("-d {directory}")),
                serde_json::json!(format!("-d {directory} --config config.head.yaml")),
            )
        );
    }
}

#[cfg(test)]
mod sidecar_command_tests {
    use super::{execute, use_hosted_sidecar_config_file};
    use crate::cli_args::clap_definitions::CommandLineArgs;
    use clap::{CommandFactory, FromArgMatches, Parser};

    // Bin.res decodes exactly this shape; the sidecar needs no codegen or Docker.
    #[tokio::test]
    async fn hands_the_runtime_the_sidecar_paths_from_the_config() {
        let directory = format!("{}/test", env!("CARGO_MANIFEST_DIR"));
        let command = execute(
            CommandLineArgs::parse_from([
                "envio",
                "sidecar",
                "-d",
                &directory,
                "--config",
                "configs/config-with-all-options.yaml",
            ]),
            None,
        )
        .await
        .expect("the command should run")
        .expect("the command should hand work to the runtime");
        let json = serde_json::to_value(&command).unwrap();
        assert_eq!(
            (
                json["kind"].clone(),
                json["env"].clone(),
                json["config"]["sidecar"].clone(),
                json["cwd"].as_str().map(|cwd| cwd.ends_with("/test")),
            ),
            (
                serde_json::json!("sidecar"),
                serde_json::json!({ "ENVIO_CONFIG": "configs/config-with-all-options.yaml" }),
                serde_json::json!({
                    "contract": "src/sidecar/contract.ts",
                    "entry": "src/sidecar/index.ts",
                }),
                Some(true),
            )
        );
    }

    // A hosted tenant's config is rarely named config.yaml.
    #[tokio::test]
    async fn names_the_config_file_that_has_no_sidecar() {
        let directory = format!("{}/test", env!("CARGO_MANIFEST_DIR"));
        let error = execute(
            CommandLineArgs::parse_from([
                "envio",
                "sidecar",
                "-d",
                &directory,
                "--config",
                "configs/config1.yaml",
            ]),
            None,
        )
        .await
        .expect_err("a config without a sidecar has nothing to run");
        assert_eq!(
            error.to_string(),
            "`envio sidecar` has nothing to run: configs/config1.yaml has no `sidecar:` key. Add \
             `sidecar: { contract: src/sidecar/contract.ts, entry: src/sidecar/index.ts }`."
        );
    }

    fn config_with_hosted_env(args: &[&str], config_file_env: Option<&str>) -> String {
        let matches = CommandLineArgs::command()
            .try_get_matches_from(args)
            .expect("the arguments should parse");
        let mut command_line_args =
            CommandLineArgs::from_arg_matches(&matches).expect("the matches should decode");
        use_hosted_sidecar_config_file(&mut command_line_args, &matches, config_file_env);
        command_line_args.project_paths.config
    }

    // Envio Cloud runs `pnpm envio sidecar` with no flags and names the tenant's
    // config file only in CONFIG_FILE (hosted-service-controller sidecar.go).
    #[test]
    fn falls_back_to_the_hosted_config_file_only_when_no_config_was_given() {
        let hosted = Some("config.base.yaml");
        assert_eq!(
            (
                config_with_hosted_env(&["envio", "sidecar"], hosted),
                config_with_hosted_env(
                    &["envio", "sidecar", "--config", "config.head.yaml"],
                    hosted
                ),
                config_with_hosted_env(&["envio", "sidecar", "--config", "config.yaml"], hosted),
                config_with_hosted_env(&["envio", "--config", "config.yaml", "sidecar"], hosted),
                config_with_hosted_env(&["envio", "sidecar"], Some("")),
                config_with_hosted_env(&["envio", "sidecar"], None),
                config_with_hosted_env(&["envio", "codegen"], hosted),
            ),
            (
                "config.base.yaml".to_string(),
                "config.head.yaml".to_string(),
                "config.yaml".to_string(),
                "config.yaml".to_string(),
                "config.yaml".to_string(),
                "config.yaml".to_string(),
                "config.yaml".to_string(),
            )
        );
    }
}
