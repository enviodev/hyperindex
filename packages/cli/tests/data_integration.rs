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

struct Output {
    stdout: String,
    stderr: String,
    ok: bool,
}

impl Output {
    fn error_message(&self) -> String {
        self.stderr
            .split("Caused by:")
            .nth(1)
            .unwrap_or(&self.stderr)
            .lines()
            .map(|l| l.trim())
            .take_while(|l| !l.starts_with("Stack backtrace:"))
            .filter(|l| !l.is_empty())
            .collect::<Vec<_>>()
            .join("\n")
    }
}

fn envio_data(args: &[&str]) -> Output {
    let output = Command::new("cargo")
        .args(["run", "--quiet", "--example", "script", "--", "data"])
        .args(args)
        .output()
        .expect("failed to execute envio data");
    Output {
        stdout: String::from_utf8_lossy(&output.stdout).to_string(),
        stderr: String::from_utf8_lossy(&output.stderr).to_string(),
        ok: output.status.success(),
    }
}

fn envio_data_no_token(args: &[&str]) -> Output {
    let output = Command::new("cargo")
        .args(["run", "--quiet", "--example", "script", "--", "data"])
        .args(args)
        .env_remove("ENVIO_API_TOKEN")
        .output()
        .expect("failed to execute envio data");
    Output {
        stdout: String::from_utf8_lossy(&output.stdout).to_string(),
        stderr: String::from_utf8_lossy(&output.stderr).to_string(),
        ok: output.status.success(),
    }
}

#[test]
fn height_returns_a_number() {
    let out = envio_data(&["knownHeight", "--chain=base"]);
    assert!(out.ok, "envio data failed: {}", out.stderr);
    assert!(
        out.stdout.starts_with("height[1]{value}:\n"),
        "unexpected stdout: {}",
        out.stdout,
    );
    let height_line = out.stdout.lines().nth(1).unwrap_or("").trim();
    let height: u64 = height_line.parse().expect("height should be a number");
    assert!(height > 1_000_000, "height suspiciously low: {height}");
}

#[test]
fn query_returns_blocks_and_logs() {
    let out = envio_data(&[
        "block.number",
        "log.srcAddress",
        "--chain=base",
        "--where={ block: { number: { _gte: 25000000, _lte: 25000020 } }, log: { srcAddress: \"0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913\" } }",
    ]);
    assert!(out.ok, "envio data failed: {}", out.stderr);
    assert!(
        out.stdout.starts_with("blocks[") && out.stdout.contains("\nlogs["),
        "unexpected stdout: {}",
        out.stdout,
    );
    assert!(
        out.stdout
            .contains("0x833589fcd6edb6e08f4c7c32d4f71b54bda02913"),
        "missing USDC address in output: {}",
        out.stdout,
    );
}

#[test]
fn no_where_pages_forward_from_genesis() {
    let out = envio_data(&["block.number", "--chain=base"]);
    assert!(out.ok, "envio data failed: {}", out.stderr);
    assert!(
        out.stderr.starts_with("\narchive_height:"),
        "unexpected stderr start: {}",
        out.stderr,
    );
}

#[test]
fn missing_token_gives_friendly_error() {
    let out = envio_data_no_token(&["knownHeight", "--chain=base"]);
    assert!(!out.ok);
    assert_eq!(
        out.error_message(),
        "ENVIO_API_TOKEN is not set.\n\
         Set the ENVIO_API_TOKEN environment variable in your .env file.\n\
         Get a free API token at: https://envio.dev/app/api-tokens",
    );
}

#[test]
fn unknown_chain_gives_friendly_error() {
    let out = envio_data(&["block.number", "--chain=bogus-network"]);
    assert!(!out.ok);
    assert_eq!(
        out.error_message(),
        "Unknown chain `bogus-network`. Pass a numeric chain id (e.g. `--chain=8453`) or\n\
         a kebab-case network name (e.g. `--chain=base`, `--chain=arbitrum-one`).",
    );
}

#[test]
fn solana_gives_not_supported_error() {
    let out = envio_data(&["knownHeight", "--chain=solana"]);
    assert!(!out.ok);
    assert_eq!(
        out.error_message(),
        "`--chain=solana` is not supported yet.\n\
         Solana support is on the roadmap. For now use an EVM chain (e.g. `--chain=base`).",
    );
}

#[test]
fn unknown_field_gives_friendly_error() {
    let out = envio_data(&["log.bogusField", "--chain=base"]);
    assert!(!out.ok);
    assert_eq!(
        out.error_message(),
        "Unknown field `log.bogusField`. Valid `log.*` fields: transactionHash, blockHash, blockNumber, transactionIndex, logIndex, srcAddress, data, removed, topic0, topic1, topic2, topic3.",
    );
}
