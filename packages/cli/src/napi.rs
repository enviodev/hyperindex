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

/// Global JS runner callback stored as an opaque thread-safe handle.
/// Set by `run_cli`, used by `execute_migration` and `start_indexer`.
static JS_RUNNER: OnceLock<ThreadsafeFunction<String>> = OnceLock::new();

/// Execute a JS script via the callback or by spawning node.
pub async fn run_js_or_spawn(
    script: &str,
    current_dir: &std::path::Path,
    extra_env: &[(String, String)],
) -> anyhow::Result<()> {
    if let Some(runner) = JS_RUNNER.get() {
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
        let script_preview: String = script.chars().take(120).collect();

        // Use a oneshot channel to wait for the JS callback completion.
        // We can't use call_async directly because its return type (Unknown)
        // isn't Send, and our async context requires Send futures.
        let (tx, rx) = tokio::sync::oneshot::channel::<Result<(), String>>();
        let tx = std::sync::Mutex::new(Some(tx));

        runner.call_with_return_value(
            Ok(full_script),
            napi::threadsafe_function::ThreadsafeFunctionCallMode::NonBlocking,
            move |result: napi::Result<napi::bindgen_prelude::Unknown>, _env: napi::Env| {
                if let Some(sender) = tx.lock().unwrap().take() {
                    match result {
                        Ok(_) => {
                            let _ = sender.send(Ok(()));
                        }
                        Err(e) => {
                            let _ = sender.send(Err(format!("{}", e)));
                        }
                    }
                }
                Ok(())
            },
        );

        rx.await
            .map_err(|_| {
                anyhow::anyhow!(
                    "JS callback channel closed unexpectedly.\nScript: {}",
                    script_preview
                )
            })?
            .map_err(|e| anyhow::anyhow!("JS script failed: {}\nScript: {}", e, script_preview))?;

        Ok(())
    } else {
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

/// Run the envio CLI. `run_js` is called instead of spawning child node
/// processes — migrations and indexer start execute in the caller's process.
#[napi_derive::napi]
pub async fn run_cli(
    args: Vec<String>,
    envio_package_dir: Option<String>,
    #[napi(ts_arg_type = "(err: null, script: string) => Promise<void>")]
    run_js: ThreadsafeFunction<String>,
) -> napi::Result<i32> {
    set_envio_package_dir(&envio_package_dir);
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
