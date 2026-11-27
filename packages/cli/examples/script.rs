// Dev-only entry point for `envio script ...` subcommands
// (`print-config-json-schema`, `print-cli-help-md`, `print-missing-networks`).
//
// The envio crate is a NAPI cdylib — real user flows run inside a Node host
// (`packages/envio/bin.mjs`). These scripts exist purely to regenerate
// committed build artifacts (json schemas, CommandLineHelp.md) from the
// Makefile, so they live as a cargo example instead of a standalone bin.
//
// Invoked via: `cargo run --example script -- script <subcommand>`
#[tokio::main]
async fn main() -> anyhow::Result<()> {
    envio::run_script_from_process_args().await
}
