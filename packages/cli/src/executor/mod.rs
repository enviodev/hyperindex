use crate::{
    clap_definitions::{ConfigSubcommand, JsonSchema, MetricsSubcommand, Script, SkillsSubcommand},
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
        /// Chains this process indexes, from `--chain`. Empty means every chain
        /// in the config, which is what a run without the flag does.
        chains: Vec<String>,
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

            // Always regenerate so the runtime never boots against stale
            // codegen output (e.g. after an `envio` package upgrade).
            // Mirrors `envio dev`; the JS side handles DB compat via
            // `envio_info`.
            commands::codegen::run_codegen(&config)
                .await
                .context("Failed running codegen")?;

            // `envio start` doesn't manage Docker — users are expected to
            // have their own services and env vars set up (e.g. via .env).
            validate_chain_selection(&config, &start_args.chains)?;

            Ok(Some(build_start_command(
                &config,
                start_args.restart,
                false,
                &[],
                start_args.chains,
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
///
/// `ENVIO_CONFIG` is root-relative: consumers resolve it against
/// `cwd` / `--directory`, so a cwd-joined value would double the prefix.
pub fn build_start_command(
    config: &SystemConfig,
    reset: bool,
    is_dev: bool,
    extra_env: &[(String, String)],
    chains: Vec<String>,
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

    Ok(Command::Start {
        reset,
        cwd: config
            .parsed_project_paths
            .project_root
            .to_string_lossy()
            .into_owned(),
        env,
        config: public_config_value(config, is_dev)?,
        chains,
    })
}

/// `--chain` splits one schema's chains across processes. Two things have to
/// hold, and both are cheaper to reject here than to discover at runtime: every
/// id has to name a configured chain, and no entity may be shared across chains,
/// since separate processes each advance their own checkpoint sequence.
fn validate_chain_selection(config: &SystemConfig, chains: &[String]) -> Result<()> {
    if chains.is_empty() {
        return Ok(());
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
        anyhow::bail!(
            "`envio start --chain` needs every entity to be per-chain, because chains indexed in \
             separate processes can't share a checkpoint sequence. Entities shared across chains: \
             {}. Drop `@crossChain` from them and set `disable_default_cross_chain: true` in \
             config.yaml, or run every chain in one process.",
            shared.join(", ")
        );
    }

    let mut configured: Vec<String> = config.chains.keys().map(|id| id.to_string()).collect();
    configured.sort_unstable();
    for chain in chains {
        if !configured.iter().any(|id| id == chain) {
            anyhow::bail!(
                "Chain {chain} is not configured, so `envio start --chain {chain}` has nothing to \
                 index. Configured chains: {}.",
                configured.join(", ")
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
        assert!(validate_chain_selection(&config, &["137".to_string()]).is_ok());
        assert!(
            validate_chain_selection(&config, &["1".to_string(), "137".to_string()]).is_ok()
        );
    }

    #[test]
    fn accepts_a_run_without_the_flag_whatever_the_schema() {
        assert!(validate_chain_selection(&config(false), &[]).is_ok());
    }

    #[test]
    fn rejects_a_chain_the_config_does_not_declare() {
        let err = validate_chain_selection(&config(true), &["42".to_string()])
            .expect_err("an unconfigured chain should be rejected");
        assert_eq!(
            err.to_string(),
            "Chain 42 is not configured, so `envio start --chain 42` has nothing to index. \
             Configured chains: 1, 137."
        );
    }

    #[test]
    fn rejects_a_schema_that_shares_entities_across_chains() {
        let err = validate_chain_selection(&config(false), &["1".to_string()])
            .expect_err("a cross-chain schema should be rejected");
        assert_eq!(
            err.to_string(),
            "`envio start --chain` needs every entity to be per-chain, because chains indexed in \
             separate processes can't share a checkpoint sequence. Entities shared across chains: \
             Counter. Drop `@crossChain` from them and set \
             `disable_default_cross_chain: true` in config.yaml, or run every chain in one process."
        );
    }
}
