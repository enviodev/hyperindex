//! End-to-end integration tests for `envio data`.
//!
//! Invokes the CLI binary (via the `script` example) and asserts on stdout/stderr.
//! Gated behind `--features integration_tests` so default `cargo test` stays offline.
//! Requires `ENVIO_API_TOKEN` in the environment.
//!
//! Run with:
//!   cargo test -p envio --features integration_tests --test data_integration
#![cfg(feature = "integration_tests")]

use std::process::Command;

fn envio_data(args: &[&str]) -> (String, String, bool) {
    let output = Command::new("cargo")
        .args(["run", "--quiet", "--example", "script", "--", "data"])
        .args(args)
        .output()
        .expect("failed to execute envio data");
    let stdout = String::from_utf8_lossy(&output.stdout).to_string();
    let stderr = String::from_utf8_lossy(&output.stderr).to_string();
    (stdout, stderr, output.status.success())
}

#[test]
fn height_returns_a_number() {
    let (stdout, stderr, ok) = envio_data(&["knownHeight", "--chain=base"]);
    assert!(ok, "envio data failed: {stderr}");
    assert!(
        stdout.contains("height[1]{value}:"),
        "stdout missing height header: {stdout}"
    );
    let height_line = stdout.lines().nth(1).unwrap_or("").trim();
    let height: u64 = height_line.parse().expect("height should be a number");
    assert!(height > 1_000_000, "height suspiciously low: {height}");
    assert!(
        stderr.contains("is at height"),
        "stderr missing friendly message: {stderr}"
    );
}

#[test]
fn query_returns_blocks_and_logs() {
    let (stdout, stderr, ok) = envio_data(&[
        "block.number",
        "log.srcAddress",
        "--chain=base",
        "--where={ block: { number: { _gte: 25000000, _lte: 25000020 } }, log: { srcAddress: \"0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913\" } }",
    ]);
    assert!(ok, "envio data failed: {stderr}");
    assert!(
        stdout.contains("blocks["),
        "missing blocks section: {stdout}"
    );
    assert!(stdout.contains("logs["), "missing logs section: {stdout}");
    assert!(
        stdout.contains("0x833589fcd6edb6e08f4c7c32d4f71b54bda02913"),
        "missing USDC address in output: {stdout}"
    );
    assert!(
        stderr.contains("Done") || stderr.contains("Next page"),
        "stderr missing pagination info: {stderr}"
    );
}

#[test]
fn no_where_pages_forward_from_genesis() {
    let (stdout, stderr, ok) = envio_data(&["block.number", "--chain=base"]);
    assert!(ok, "envio data failed: {stderr}");
    assert!(
        stderr.contains("next_block:"),
        "stderr missing next_block: {stderr}"
    );
}

#[test]
fn missing_token_gives_friendly_error() {
    let output = Command::new("cargo")
        .args(["run", "--quiet", "--example", "script", "--", "data"])
        .args(["knownHeight", "--chain=base"])
        .env_remove("ENVIO_API_TOKEN")
        .output()
        .expect("failed to execute");
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(!output.status.success());
    assert!(
        stderr.contains("ENVIO_API_TOKEN") && stderr.contains("envio.dev"),
        "missing friendly token error: {stderr}"
    );
}

#[test]
fn unknown_chain_gives_friendly_error() {
    let (_, stderr, ok) = envio_data(&["block.number", "--chain=bogus-network"]);
    assert!(!ok);
    assert!(
        stderr.contains("Unknown chain") || stderr.contains("--chain=base"),
        "missing chain hint: {stderr}"
    );
}

#[test]
fn solana_gives_not_supported_error() {
    let (_, stderr, ok) = envio_data(&["knownHeight", "--chain=solana"]);
    assert!(!ok);
    assert!(
        stderr.contains("not supported yet"),
        "missing solana message: {stderr}"
    );
}

#[test]
fn unknown_field_gives_friendly_error() {
    let (_, stderr, ok) = envio_data(&["log.bogusField", "--chain=base"]);
    assert!(!ok);
    assert!(
        stderr.contains("Unknown field") && stderr.contains("srcAddress"),
        "missing field hint: {stderr}"
    );
}
