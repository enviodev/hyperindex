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

impl std::fmt::Display for Output {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "exit: {}\n--- stdout ---\n{}\n--- stderr ---\n{}",
            if self.ok { "ok" } else { "FAIL" },
            self.stdout,
            self.stderr,
        )
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

#[test]
fn height_returns_a_number() {
    let out = envio_data(&["knownHeight", "--chain=base"]);
    assert!(out.ok, "envio data failed:\n{out}");
    assert!(
        out.stdout.starts_with("height[1]{value}:\n"),
        "unexpected output:\n{out}",
    );
    let height_line = out.stdout.lines().nth(1).unwrap_or("").trim();
    let height: u64 = height_line
        .parse()
        .unwrap_or_else(|_| panic!("height should be a number:\n{out}"));
    assert!(height > 1_000_000, "height suspiciously low:\n{out}");
}

#[test]
fn query_returns_blocks_and_logs() {
    let out = envio_data(&[
        "block.number",
        "log.srcAddress",
        "--chain=base",
        "--where={ block: { number: { _gte: 25000000, _lte: 25000020 } }, log: { srcAddress: \"0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913\" } }",
    ]);
    assert!(out.ok, "envio data failed:\n{out}");
    assert!(
        out.stdout.starts_with("blocks[") && out.stdout.contains("\nlogs["),
        "unexpected output:\n{out}",
    );
    assert!(
        out.stdout
            .contains("0x833589fcd6edb6e08f4c7c32d4f71b54bda02913"),
        "missing USDC address:\n{out}",
    );
}

#[test]
fn no_where_pages_forward_from_genesis() {
    let out = envio_data(&["block.number", "--chain=base"]);
    assert!(out.ok, "envio data failed:\n{out}");
    assert!(
        out.stderr.starts_with("\narchive_height:"),
        "unexpected output:\n{out}",
    );
}
