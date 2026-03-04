use napi_derive::napi;

/// Run the envio CLI with the given argv (excluding the binary name).
/// Example from JS: `run(["codegen"])` is equivalent to `envio codegen`.
#[napi]
pub fn run(argv: Vec<String>) -> napi::Result<()> {
    use crate::{clap_definitions::CommandLineArgs, executor};
    use clap::Parser;

    // Build a full argv: clap expects argv[0] to be the program name.
    let mut full_argv = vec!["envio".to_string()];
    full_argv.extend(argv);

    let command_line_args = CommandLineArgs::try_parse_from(full_argv)
        .map_err(|e| napi::Error::from_reason(e.to_string()))?;

    tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .map_err(|e| napi::Error::from_reason(format!("Failed to create tokio runtime: {e}")))?
        .block_on(executor::execute(command_line_args))
        .map_err(|e| napi::Error::from_reason(format!("{e:?}")))?;

    Ok(())
}
