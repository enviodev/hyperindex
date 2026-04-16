use crate::{
    clap_definitions::CommandLineArgs, config_parsing::system_config::SystemConfig,
    project_paths::ParsedProjectPaths,
};
use anyhow::Context;
use clap::{CommandFactory, FromArgMatches};
use napi::threadsafe_function::ThreadsafeFunction;
use std::sync::OnceLock;

fn set_envio_package_dir(dir: &Option<String>) {
    if let Some(d) = dir {
        std::env::set_var("ENVIO_PACKAGE_DIR", d);
    }
}

/// Global JS runner callback. Set by `run_cli` before executing commands.
/// Rust calls this instead of spawning child Node processes.
static JS_RUNNER: OnceLock<ThreadsafeFunction<String, ()>> = OnceLock::new();

/// Execute a JS script in the caller's Node process via the callback.
/// Falls back to spawning `node -e <script>` if no callback is set.
pub async fn run_js_or_spawn(
    script: &str,
    current_dir: &std::path::Path,
    extra_env: &[(String, String)],
) -> anyhow::Result<()> {
    if let Some(runner) = JS_RUNNER.get() {
        // Build env setup + cwd change as JS prefix
        let env_setup: String = extra_env
            .iter()
            .map(|(k, v)| {
                format!(
                    "process.env[{}] = {};",
                    serde_json::to_string(k).unwrap_or_default(),
                    serde_json::to_string(v).unwrap_or_default()
                )
            })
            .collect::<Vec<_>>()
            .join("");

        let cwd_setup = format!(
            "process.chdir({});",
            serde_json::to_string(&current_dir.to_string_lossy()).unwrap_or_default()
        );

        let full_script = format!("{}{}{}", cwd_setup, env_setup, script);

        runner
            .call_async(Ok(full_script))
            .await
            .map_err(|e| anyhow::anyhow!("JS callback failed: {}", e))?;

        Ok(())
    } else {
        // Fallback: spawn node process (for non-NAPI invocations)
        let mut cmd = tokio::process::Command::new("node");
        cmd.args(["-e", script])
            .current_dir(current_dir)
            .stdin(std::process::Stdio::null())
            .kill_on_drop(true);

        for (k, v) in extra_env {
            cmd.env(k, v);
        }

        let exit = cmd.spawn()?.wait().await?;

        if !exit.success() {
            return Err(anyhow::anyhow!(
                "Node script exited with code {}",
                exit.code().unwrap_or(-1)
            ));
        }
        Ok(())
    }
}

#[napi_derive::napi]
pub fn get_config_json(
    config_path: Option<String>,
    directory: Option<String>,
    envio_package_dir: Option<String>,
) -> napi::Result<String> {
    set_envio_package_dir(&envio_package_dir);

    let project_root = directory.unwrap_or_else(|| ".".to_string());
    let config = config_path
        .or_else(|| std::env::var("ENVIO_CONFIG").ok())
        .unwrap_or_else(|| "config.yaml".to_string());

    let project_paths = ParsedProjectPaths::new(&project_root, "generated", &config)
        .map_err(|e| napi::Error::from_reason(format!("Failed parsing project paths: {e}")))?;

    let system_config = SystemConfig::parse_from_project_files(&project_paths)
        .map_err(|e| napi::Error::from_reason(format!("{e}")))?;

    system_config
        .to_public_config_json()
        .map_err(|e| napi::Error::from_reason(format!("Failed serializing config: {e}")))
}

/// Run the envio CLI with the given arguments.
///
/// `run_js` is a callback that Rust calls to execute JS code in the
/// caller's Node process — used for migrations and indexer start instead
/// of spawning child `node` processes.
#[napi_derive::napi]
pub async fn run_cli(
    args: Vec<String>,
    envio_package_dir: Option<String>,
    #[napi(ts_arg_type = "(script: string) => Promise<void>")] run_js: ThreadsafeFunction<
        String,
        (),
    >,
) -> napi::Result<i32> {
    set_envio_package_dir(&envio_package_dir);

    // Store the callback globally so commands.rs can use it
    let _ = JS_RUNNER.set(run_js);

    let mut full_args = vec!["envio".to_string()];
    full_args.extend(args);

    let matches = CommandLineArgs::command()
        .version(crate::config_parsing::system_config::VERSION)
        .try_get_matches_from(&full_args)
        .map_err(|e| {
            if e.use_stderr() {
                napi::Error::from_reason(format!("{e}"))
            } else {
                print!("{e}");
                napi::Error::from_reason("__exit_0__".to_string())
            }
        })?;

    let command_line_args = CommandLineArgs::from_arg_matches(&matches)
        .context("Failed parsing command line arguments")
        .map_err(|e| napi::Error::from_reason(format!("{e}")))?;

    crate::executor::execute(command_line_args)
        .await
        .map_err(|e| napi::Error::from_reason(format!("{e}")))?;

    Ok(0)
}
