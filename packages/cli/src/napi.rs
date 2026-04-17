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

static JS_RUNNER: OnceLock<ThreadsafeFunction<String>> = OnceLock::new();

type WaiterMap = HashMap<u64, tokio::sync::oneshot::Sender<Result<(), String>>>;
static WAITERS: OnceLock<Mutex<WaiterMap>> = OnceLock::new();

fn get_waiters() -> &'static Mutex<WaiterMap> {
    WAITERS.get_or_init(|| Mutex::new(HashMap::new()))
}

static NEXT_ID: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(1);

#[napi_derive::napi]
pub fn signal_complete(id: f64) {
    let id = id as u64;
    if let Some(tx) = get_waiters().lock().unwrap().remove(&id) {
        let _ = tx.send(Ok(()));
    }
}

#[napi_derive::napi]
pub fn signal_error(id: f64, msg: String) {
    let id = id as u64;
    if let Some(tx) = get_waiters().lock().unwrap().remove(&id) {
        let _ = tx.send(Err(msg));
    }
}

/// Send a structured command to the JS callback and await completion.
/// Format: "id|command|json-data"
pub async fn run_command(command: &str, data: &serde_json::Value) -> anyhow::Result<()> {
    if let Some(runner) = JS_RUNNER.get() {
        let id = NEXT_ID.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let (tx, rx) = tokio::sync::oneshot::channel::<Result<(), String>>();
        get_waiters().lock().unwrap().insert(id, tx);

        let payload = format!("{}|{}|{}", id, command, data);

        runner.call_with_return_value(
            Ok(payload),
            napi::threadsafe_function::ThreadsafeFunctionCallMode::NonBlocking,
            |_result: napi::Result<napi::bindgen_prelude::Unknown>, _env: napi::Env| Ok(()),
        );

        rx.await
            .map_err(|_| anyhow::anyhow!("JS callback channel closed for command: {}", command))?
            .map_err(|e| anyhow::anyhow!("{}", e))?;

        Ok(())
    } else {
        Err(anyhow::anyhow!(
            "No JS runner available. This command requires running via the envio npm package."
        ))
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
