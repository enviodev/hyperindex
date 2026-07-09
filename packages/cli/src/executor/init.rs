use crate::{
    cli_args::{
        clap_definitions::{InitArgs, ProjectPaths},
        init_config::{self, Ecosystem, Language},
        interactive_init::prompt_missing_init_args,
    },
    commands,
    config_parsing::{
        entity_parsing::Schema,
        human_config::HumanConfig,
        system_config::{get_envio_version, SystemConfig},
    },
    hbs_templating::{
        contract_import_templates, hbs_dir_generator::HandleBarsDirGenerator,
        init_templates::InitTemplates,
    },
    project_paths::ParsedProjectPaths,
    template_dirs::TemplateDirs,
    utils::file_system,
};
use anyhow::{Context, Result};

use std::io::{IsTerminal, Write};
use std::path::Path;

/// Exit code used when `envio init` short-circuits with an agent prompt.
/// Distinct from 1 (generic failure) so coding agents can tell "the user
/// needs to take a follow-up step" from "the command actually failed".
pub const AGENTIC_INIT_EXIT_CODE: i32 = 2;

pub async fn run_init_args(
    init_args: InitArgs,
    project_paths: &ProjectPaths,
    envio_package_dir: Option<&str>,
) -> Result<()> {
    let template_dirs = TemplateDirs::new();

    // When no subcommand is given and we detect we're being driven by an AI
    // agent (or otherwise running non-interactively), short-circuit with an
    // agent-readable prompt instead of stalling on an `inquire` Select that
    // can't be answered.
    //
    // Writing straight to stderr + `process::exit` keeps the prompt pristine:
    // routing it through `anyhow::bail!` would pass it through the JS host's
    // `Logging.error`, which wraps the message in pino's JSON envelope and
    // buries the steps the agent needs to read.
    let is_non_interactive = is_agentic_init_mode(&AgenticEnv::from_process());
    if init_args.init_commands.is_none() && is_non_interactive {
        let prompt = agentic_init_prompt(init_args.api_token.is_some());
        let mut stderr = std::io::stderr().lock();
        let _ = stderr.write_all(prompt.as_bytes());
        let _ = stderr.flush();
        std::process::exit(AGENTIC_INIT_EXIT_CODE);
    }

    //get_init_args_interactive opens an interactive cli for required args to be selected
    //if they haven't already been
    let init_config = prompt_missing_init_args(init_args, project_paths, is_non_interactive)
        .await
        .context("Failed during interactive input")?;

    let parsed_project_paths = ParsedProjectPaths::try_from(init_config.clone())
        .context("Failed parsing paths from interactive input")?;
    // The cli errors if the folder exists, the user must provide a new folder to proceed which we create below
    std::fs::create_dir_all(&parsed_project_paths.project_root)?;

    match &init_config.ecosystem {
        Ecosystem::Fuel {
            init_flow: init_config::fuel::InitFlow::Template(template),
        } => {
            template_dirs
                .get_and_extract_template(
                    template,
                    &Language::TypeScript,
                    &parsed_project_paths.project_root,
                )
                .context(format!(
                    "Failed initializing Fuel template {} at path {:?}",
                    template, parsed_project_paths.project_root,
                ))?;
        }
        Ecosystem::Svm {
            init_flow: init_config::svm::InitFlow::Template(template),
        } => {
            template_dirs
                .get_and_extract_template(
                    template,
                    &Language::TypeScript,
                    &parsed_project_paths.project_root,
                )
                .context(format!(
                    "Failed initializing Svm template {} at path {:?}",
                    template, parsed_project_paths.project_root,
                ))?;
        }
        Ecosystem::Evm {
            init_flow: init_config::evm::InitFlow::Template(template),
        } => {
            template_dirs
                .get_and_extract_template(
                    template,
                    &Language::TypeScript,
                    &parsed_project_paths.project_root,
                )
                .context(format!(
                    "Failed initializing Evm template {} at path {:?}",
                    template, parsed_project_paths.project_root,
                ))?;
        }
        Ecosystem::Fuel {
            init_flow: init_config::fuel::InitFlow::ContractImport(contract_import_selection),
        } => {
            let fuel_config = contract_import_selection.to_human_config(&init_config);

            let addresses = fuel_config
                .chains
                .iter()
                .filter_map(|chain| chain.contracts.as_ref())
                .flatten()
                .flat_map(|contract| contract.address.iter().cloned());

            // TODO: Allow parsed paths to not depend on a written config.yaml file in file system
            file_system::write_file_string_to_system(
                crate::config_parsing::human_config::quote_known_addresses(
                    fuel_config.to_string(),
                    addresses,
                ),
                parsed_project_paths.project_root.join("config.yaml"),
            )
            .await
            .context("Failed writing imported config.yaml")?;

            for selected_contract in &contract_import_selection.contracts {
                file_system::write_file_string_to_system(
                    selected_contract.abi.raw.clone(),
                    parsed_project_paths
                        .project_root
                        .join(selected_contract.get_vendored_abi_file_path()),
                )
                .await
                .context(format!(
                    "Failed vendoring ABI file for {} contract",
                    selected_contract.name
                ))?;
            }

            //Use an empty schema config to generate auto_schema_handler_template
            //After it's been generated, the schema exists and codegen can parse it/use it
            let system_config = SystemConfig::from_human_config(
                HumanConfig::Fuel(fuel_config),
                Schema::empty(),
                &parsed_project_paths,
            )
            .context("Failed parsing config")?;

            let auto_schema_handler_template =
                contract_import_templates::AutoSchemaHandlerTemplate::try_from(
                    system_config,
                    &init_config.language,
                    init_config.api_token.clone(),
                )
                .context("Failed converting config to auto auto_schema_handler_template")?;

            template_dirs
                .get_and_extract_blank_template(
                    &init_config.language,
                    &parsed_project_paths.project_root,
                )
                .context(format!(
                    "Failed initializing blank template for Contract Import with language {} at \
                     path {:?}",
                    init_config.language, parsed_project_paths.project_root,
                ))?;

            auto_schema_handler_template
                .generate_contract_import_templates(
                    &init_config.language,
                    &parsed_project_paths.project_root,
                    true, // is_fuel
                )
                .context(
                    "Failed generating contract import templates for schema and event handlers.",
                )?;
        }

        Ecosystem::Evm {
            init_flow: init_config::evm::InitFlow::ContractImport(auto_config_selection),
        } => {
            let evm_config = auto_config_selection
                .to_human_config(&init_config)
                .context("Failed to converting auto config selection into config.yaml")?;

            let addresses = evm_config
                .chains
                .iter()
                .filter_map(|chain| chain.contracts.as_ref())
                .flatten()
                .flat_map(|contract| contract.address.iter().cloned());

            // TODO: Allow parsed paths to not depend on a written config.yaml file in file system
            file_system::write_file_string_to_system(
                crate::config_parsing::human_config::quote_known_addresses(
                    evm_config.to_string(),
                    addresses,
                ),
                parsed_project_paths.project_root.join("config.yaml"),
            )
            .await
            .context("failed writing imported config.yaml")?;

            //Use an empty schema config to generate auto_schema_handler_template
            //After it's been generated, the schema exists and codegen can parse it/use it
            let system_config = SystemConfig::from_human_config(
                HumanConfig::Evm(evm_config),
                Schema::empty(),
                &parsed_project_paths,
            )
            .context("Failed parsing config")?;

            let auto_schema_handler_template =
                contract_import_templates::AutoSchemaHandlerTemplate::try_from(
                    system_config,
                    &init_config.language,
                    init_config.api_token.clone(),
                )
                .context("Failed converting config to auto auto_schema_handler_template")?;

            template_dirs
                .get_and_extract_blank_template(
                    &init_config.language,
                    &parsed_project_paths.project_root,
                )
                .context(format!(
                    "Failed initializing blank template for Contract Import with language {} at \
                     path {:?}",
                    init_config.language, parsed_project_paths.project_root,
                ))?;

            auto_schema_handler_template
                .generate_contract_import_templates(
                    &init_config.language,
                    &parsed_project_paths.project_root,
                    false, // is_fuel
                )
                .context(
                    "Failed generating contract import templates for schema and event handlers.",
                )?;
        }
    }

    let envio_version = get_envio_version(envio_package_dir)?;

    let extra_dependencies = match &init_config.ecosystem {
        Ecosystem::Evm {
            init_flow:
                init_config::evm::InitFlow::Template(init_config::evm::Template::FeatureExternalCalls),
        } => vec![("viem".to_string(), "2.54.0".to_string())],
        _ => vec![],
    };

    let hbs_template = InitTemplates::new(
        init_config.name.clone(),
        &init_config.language,
        envio_version.clone(),
        init_config.api_token,
        extra_dependencies,
    );

    let init_shared_template_dir = template_dirs.get_init_template_dynamic_shared()?;

    let hbs_generator = HandleBarsDirGenerator::new(
        &init_shared_template_dir,
        &hbs_template,
        &parsed_project_paths.project_root,
    );

    hbs_generator.generate_hbs_templates()?;

    println!("Project template ready");
    println!("Running codegen");

    let config = SystemConfig::parse_from_project_files(&parsed_project_paths)
        .context("Failed parsing config")?;

    commands::codegen::run_codegen(&config).await?;

    let pm = init_config.package_manager;
    println!("Installing dependencies with {}...", pm);
    commands::pm::install(pm, &parsed_project_paths.project_root)
        .await
        .context("Failed installing project dependencies")?;

    if init_config.language == Language::ReScript {
        println!("Building ReScript sources...");
        commands::pm::run_script(pm, "build", &parsed_project_paths.project_root)
            .await
            .context("Failed running ReScript build after init")?;
    }

    // Initialize git repository (non-fatal if it fails)
    match commands::git::init(&parsed_project_paths.project_root).await {
        Ok(true) => println!("Initialized a new git repository."),
        Ok(false) => {} // Already inside a git repo, nothing to report
        Err(e) => eprintln!("Warning: Failed to initialize git repository: {}", e),
    }

    print!(
        "{}",
        next_steps_message(&parsed_project_paths.project_root, pm)
    );

    Ok(())
}

fn next_steps_message(project_root: &Path, pm: init_config::PackageManager) -> String {
    use std::fmt::Write;

    let mut out = String::new();
    out.push('\n');
    out.push_str("Your indexer is ready! Pick how you'd like to run it:\n");
    out.push('\n');

    let in_current_dir = project_root
        .components()
        .all(|c| matches!(c, std::path::Component::CurDir));
    let prefix = if in_current_dir {
        String::new()
    } else {
        format!(
            "cd {} && ",
            shell_quote(&project_root.display().to_string())
        )
    };
    let cmd = pm.cmd();

    let _ = writeln!(
        out,
        "  1. {prefix}{cmd} test    # run the tests (recommended for AI)"
    );
    let _ = writeln!(out, "  2. {prefix}{cmd} dev     # run locally");
    let _ = writeln!(out, "  3. {prefix}{cmd} start   # run in production");

    out
}

/// Inputs that decide whether `envio init` should print an agentic prompt
/// instead of opening interactive selects. Pulled into a struct so tests can
/// drive the logic without touching the real process env / TTY.
///
/// Mirrors the predicate `Envio.isNonInteractive` in
/// `packages/envio/src/Envio.res` so a project picks up the same TUI/agent
/// classification at init time as it will at runtime.
struct AgenticEnv {
    envio_tui: Option<String>,
    stdout_is_tty: bool,
    claudecode: bool,
    ci: bool,
    term: Option<String>,
}

impl AgenticEnv {
    fn from_process() -> Self {
        Self {
            envio_tui: std::env::var("ENVIO_TUI").ok(),
            stdout_is_tty: std::io::stdout().is_terminal(),
            claudecode: std::env::var("CLAUDECODE").is_ok(),
            ci: std::env::var("CI").is_ok(),
            term: std::env::var("TERM").ok(),
        }
    }
}

fn is_agentic_init_mode(env: &AgenticEnv) -> bool {
    // ENVIO_TUI mirrors the runtime override in `Main.res`: an explicit value
    // wins in either direction.
    match env.envio_tui.as_deref() {
        Some("true") | Some("1") => return false,
        Some("false") | Some("0") => return true,
        _ => {}
    }
    !env.stdout_is_tty || env.claudecode || env.ci || env.term.as_deref() == Some("dumb")
}

/// `--help` preamble for `envio init`, shown before clap's generated usage.
/// Agents reflexively probe `--help` before running a command; leading with the
/// zero-arg quick start keeps them on the supported path instead of the
/// advanced subcommands. The detailed plan is left to the bare command, which
/// prints it once the agent actually runs `envio init`.
pub fn init_help_preamble() -> String {
    let mut out = String::new();
    out.push_str("Quick start — run with no arguments:\n\n  pnpx envio init\n\n");
    out.push_str(
        "Guided step-by-step for humans and AI agents. Reach for the subcommands below only when \
         you already know exactly what you want.\n",
    );
    out
}

fn agentic_init_prompt(has_api_token: bool) -> String {
    use std::fmt::Write;

    let mut out = String::new();
    out.push_str(
        "Welcome to Envio Indexer! Let's set up an indexer that will become a reliable \
         blockchain backend you trust, love, and own.\n\n",
    );
    out.push_str("Leave the rest to your favorite agent:\n\n");

    let mut step = 1;
    if !has_api_token {
        let _ = writeln!(
            out,
            "  {step}. ENVIO_API_TOKEN is not set. Ask the user to create one at \
             https://envio.dev/app/api-tokens and provide it to the session before continuing."
        );
        step += 1;
    }
    let _ = writeln!(
        out,
        "  {step}. Prompt the user for the project intent if it is missing from context \
         (what should the indexer track and surface?)."
    );
    step += 1;
    let _ = writeln!(
        out,
        "  {step}. Determine the chain, contract, and addresses needed to produce that result. \
         Use web search or block-explorer tool calls when the user hasn't supplied them."
    );
    step += 1;
    let _ = writeln!(out, "  {step}. To continue, call:");
    out.push('\n');
    out.push_str("pnpx envio init contract-import explorer \\\n");
    out.push_str("  -n ${indexer-name} \\\n");
    out.push_str("  -c ${address} \\\n");
    out.push_str("  -b ${chainId} \\\n");
    out.push_str("  --single-contract \\\n");
    out.push_str("  --all-events \\\n");
    out.push_str("  -d ${directory}\n");
    out.push('\n');
    out.push_str(
        "Then `cd ${directory}` and run `pnpm test`. Don't hand the project off yet — keep \
         iterating on the indexer with a TDD loop (extend tests, run them, fix handlers) until \
         the user's goal is met.\n",
    );
    out
}

/// Leave alphanumeric paths unquoted; single-quote anything containing chars
/// the shell would interpret (spaces, `$`, backticks, `&`, `;`, etc.) so the
/// printed `cd <path>` is safe to paste. Folder name validation rejects `'`,
/// so a plain single-quote wrap is sufficient.
fn shell_quote(s: &str) -> String {
    let safe = !s.is_empty()
        && s.chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.' | '/'));
    if safe {
        s.to_string()
    } else {
        format!("'{s}'")
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cli_args::init_config::PackageManager;

    #[test]
    fn next_steps_in_subdir() {
        insta::assert_snapshot!(next_steps_message(
            Path::new("my-indexer"),
            PackageManager::Pnpm
        ));
    }

    #[test]
    fn next_steps_in_current_dir() {
        insta::assert_snapshot!(next_steps_message(Path::new("."), PackageManager::Npm));
    }

    #[test]
    fn next_steps_in_subdir_with_spaces() {
        insta::assert_snapshot!(next_steps_message(
            Path::new("my indexer"),
            PackageManager::Npm
        ));
    }

    #[test]
    fn next_steps_in_subdir_with_shell_metacharacters() {
        insta::assert_snapshot!(next_steps_message(
            Path::new("my-$HOME-`tmp`"),
            PackageManager::Npm
        ));
    }

    #[test]
    fn next_steps_in_current_dir_alias() {
        insta::assert_snapshot!(next_steps_message(Path::new("./"), PackageManager::Npm));
    }

    fn env(
        envio_tui: Option<&str>,
        stdout_is_tty: bool,
        claudecode: bool,
        ci: bool,
        term: Option<&str>,
    ) -> AgenticEnv {
        AgenticEnv {
            envio_tui: envio_tui.map(str::to_string),
            stdout_is_tty,
            claudecode,
            ci,
            term: term.map(str::to_string),
        }
    }

    #[test]
    fn agentic_mode_detection_matrix() {
        let cases = vec![
            (
                "plain interactive tty",
                env(None, true, false, false, Some("xterm-256color")),
                false,
            ),
            (
                "piped stdout",
                env(None, false, false, false, Some("xterm-256color")),
                true,
            ),
            (
                "claudecode set",
                env(None, true, true, false, Some("xterm-256color")),
                true,
            ),
            (
                "ci set",
                env(None, true, false, true, Some("xterm-256color")),
                true,
            ),
            (
                "term=dumb",
                env(None, true, false, false, Some("dumb")),
                true,
            ),
            (
                "envio_tui=false overrides tty",
                env(Some("false"), true, false, false, Some("xterm-256color")),
                true,
            ),
            (
                "envio_tui=true overrides agent",
                env(Some("true"), false, true, false, Some("dumb")),
                false,
            ),
            (
                "envio_tui=1 forces interactive",
                env(Some("1"), false, true, true, Some("dumb")),
                false,
            ),
            (
                "envio_tui=0 forces agentic",
                env(Some("0"), true, false, false, Some("xterm-256color")),
                true,
            ),
        ];

        let report: String = cases
            .into_iter()
            .map(|(label, env, expected)| {
                let got = is_agentic_init_mode(&env);
                assert_eq!(got, expected, "case {label}");
                format!("{label}: {got}")
            })
            .collect::<Vec<_>>()
            .join("\n");
        insta::assert_snapshot!(report);
    }

    #[test]
    fn agentic_prompt_without_api_token() {
        insta::assert_snapshot!(agentic_init_prompt(false));
    }

    #[test]
    fn agentic_prompt_with_api_token() {
        insta::assert_snapshot!(agentic_init_prompt(true));
    }
}
