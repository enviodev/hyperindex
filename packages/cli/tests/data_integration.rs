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

impl Output {
    fn stderr_template(&self) -> String {
        self.stderr
            .trim()
            .lines()
            .map(|line| {
                let mut result = String::new();
                let mut chars = line.chars().peekable();
                while let Some(ch) = chars.next() {
                    if ch.is_ascii_digit() {
                        while chars.peek().is_some_and(|c| c.is_ascii_digit()) {
                            chars.next();
                        }
                        result.push_str("<N>");
                    } else {
                        result.push(ch);
                    }
                }
                result
            })
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

#[test]
fn height_returns_a_number() {
    let out = envio_data(&["knownHeight", "--chain=base"]);
    assert!(out.ok, "envio data failed:\n{out}");

    let lines: Vec<&str> = out.stdout.lines().collect();
    assert_eq!(
        lines[0], "knownHeight[1]{value}:",
        "unexpected stdout:\n{out}"
    );
    let height: u64 = lines[1]
        .trim()
        .parse()
        .unwrap_or_else(|_| panic!("height should be a number:\n{out}"));
    assert!(height > 1_000_000, "height suspiciously low:\n{out}");

    assert_eq!(
        out.stderr_template(),
        "Chain <N> is at height <N>.",
        "unexpected stderr:\n{out}",
    );
}

/// Historical block 20000000 on Ethereum mainnet — deterministic output.
/// Queries USDT Transfer events (11 in this block).
#[test]
fn query_returns_deterministic_block_and_log_data() {
    let out = envio_data(&[
        "block.number",
        "block.gasUsed",
        "log.srcAddress",
        "log.logIndex",
        "--chain=1",
        "--where={ block: { number: { _gte: 20000000, _lte: 20000000 } }, log: { srcAddress: \"0xdAC17F958D2ee523a2206206994597C13D831ec7\", topic0: \"0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef\" } }",
    ]);
    assert!(out.ok, "envio data failed:\n{out}");

    assert_eq!(
        out.stdout,
        "\
blocks[1]{number,gasUsed}:
  20000000,11089692
logs[11]{srcAddress,logIndex}:
  0xdac17f958d2ee523a2206206994597c13d831ec7,86
  0xdac17f958d2ee523a2206206994597c13d831ec7,89
  0xdac17f958d2ee523a2206206994597c13d831ec7,108
  0xdac17f958d2ee523a2206206994597c13d831ec7,111
  0xdac17f958d2ee523a2206206994597c13d831ec7,112
  0xdac17f958d2ee523a2206206994597c13d831ec7,125
  0xdac17f958d2ee523a2206206994597c13d831ec7,132
  0xdac17f958d2ee523a2206206994597c13d831ec7,133
  0xdac17f958d2ee523a2206206994597c13d831ec7,172
  0xdac17f958d2ee523a2206206994597c13d831ec7,208
  0xdac17f958d2ee523a2206206994597c13d831ec7,209
",
        "unexpected stdout:\n{out}",
    );

    assert_eq!(out.stderr_template(), "", "unexpected stderr:\n{out}");
}

#[test]
fn no_where_pages_forward_from_genesis() {
    let out = envio_data(&["block.number", "--chain=base"]);
    assert!(out.ok, "envio data failed:\n{out}");

    assert_eq!(
        out.stdout, "blocks[0]{number}:\n",
        "unexpected stdout:\n{out}",
    );

    let expected = [
        "Got a response up to block <N>. To get the next page, run the following command:",
        "  envio data block.number \\",
        "    --chain=base \\",
        "    --where='{ block: { number: { _gte: <N> } } }'",
    ]
    .join("\n");
    assert_eq!(out.stderr_template(), expected, "unexpected stderr:\n{out}");
}
