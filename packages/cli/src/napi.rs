use crate::{
    clap_definitions::CommandLineArgs, config_parsing::system_config::SystemConfig,
    project_paths::ParsedProjectPaths,
};
use anyhow::Context;
use clap::{CommandFactory, FromArgMatches};
use napi::threadsafe_function::ThreadsafeFunction;
use std::collections::HashMap;
use std::sync::{Mutex, OnceLock};

fn set_envio_package_dir(dir: &Option<String>) {
    if let Some(d) = dir {
        std::env::set_var("ENVIO_PACKAGE_DIR", d);
    }
}

/// Global JS runner callback.
static JS_RUNNER: OnceLock<ThreadsafeFunction<String>> = OnceLock::new();

/// Pending completion signals keyed by request ID.
static WAITERS: OnceLock<Mutex<HashMap<u64, tokio::sync::oneshot::Sender<Result<(), String>>>>> =
    OnceLock::new();

fn get_waiters() -> &'static Mutex<HashMap<u64, tokio::sync::oneshot::Sender<Result<(), String>>>> {
    WAITERS.get_or_init(|| Mutex::new(HashMap::new()))
}

static NEXT_ID: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(1);

/// Called by JS when an async script completes successfully.
#[napi_derive::napi]
pub fn signal_complete(id: f64) {
    let id = id as u64;
    if let Some(tx) = get_waiters().lock().unwrap().remove(&id) {
        let _ = tx.send(Ok(()));
    }
}

/// Called by JS when an async script fails.
#[napi_derive::napi]
pub fn signal_error(id: f64, msg: String) {
    let id = id as u64;
    if let Some(tx) = get_waiters().lock().unwrap().remove(&id) {
        let _ = tx.send(Err(msg));
    }
}

/// Execute a JS script in-process via the callback, or spawn node as fallback.
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

        // Create a unique ID and channel for this call
        let id = NEXT_ID.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let (tx, rx) = tokio::sync::oneshot::channel::<Result<(), String>>();
        get_waiters().lock().unwrap().insert(id, tx);

        // Send the script with ID prefix. The JS callback parses the ID,
        // runs the script, then calls signalComplete/signalError.
        let payload = format!("{}|{}{}{}", id, cwd_setup, env_setup, script);
        let script_preview: String = script.chars().take(120).collect();

        runner.call_with_return_value(
            Ok(payload),
            napi::threadsafe_function::ThreadsafeFunctionCallMode::NonBlocking,
            |_result: napi::Result<napi::bindgen_prelude::Unknown>, _env: napi::Env| Ok(()),
        );

        rx.await
            .map_err(|_| {
                anyhow::anyhow!(
                    "JS callback channel closed unexpectedly.\nScript: {}",
                    script_preview
                )
            })?
            .map_err(|e| anyhow::anyhow!("{}\nScript: {}", e, script_preview))?;

        Ok(())
    } else {
        // Fallback: spawn node (non-NAPI invocations)
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

#[napi_derive::napi]
pub async fn run_cli(
    args: Vec<String>,
    envio_package_dir: Option<String>,
    #[napi(ts_arg_type = "(err: null, payload: string) => void")] run_js: ThreadsafeFunction<
        String,
    >,
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
