//! End-to-end integration tests for `envio data`.
//!
//! Invokes the CLI binary (via the `script` example) and asserts on stdout/stderr.
//! Runs as part of the normal `cargo test` flow; each test silently skips when
//! `ENVIO_API_TOKEN` is absent so the suite stays green locally and on forks
//! that don't have access to the secret.

use std::process::Command;

fn skip_without_token() -> bool {
    let has_token = std::env::var_os("ENVIO_API_TOKEN").is_some_and(|v| !v.is_empty());
    if !has_token {
        eprintln!("skipping: ENVIO_API_TOKEN not set");
    }
    !has_token
}

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
        // `\b\d+\b` only matches standalone integer literals — digits embedded
        // in hex strings like `0xdAC17F958...` keep their literal characters
        // so the assertion can compare the address bytes exactly.
        regex::Regex::new(r"\b\d+\b")
            .unwrap()
            .replace_all(self.stderr.trim(), "<N>")
            .into_owned()
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
    if skip_without_token() {
        return;
    }
    let out = envio_data(&["knownHeight", "--chain=base"]);
    assert!(out.ok, "envio data failed:\n{out}");

    let stripped = out
        .stdout
        .strip_prefix("knownHeight: ")
        .and_then(|s| s.strip_suffix('\n'))
        .unwrap_or_else(|| panic!("unexpected stdout:\n{out}"));
    let height: u64 = stripped
        .parse()
        .unwrap_or_else(|_| panic!("height should be a number:\n{out}"));
    assert!(height > 1_000_000, "height suspiciously low:\n{out}");

    assert_eq!(
        out.stderr_template(),
        "Chain base is at height <N>.",
        "unexpected stderr:\n{out}",
    );
}

/// Historical block 20000000 on Ethereum mainnet — deterministic output.
/// Queries USDT Transfer events (11 in this block).
#[test]
fn query_returns_deterministic_block_and_log_data() {
    if skip_without_token() {
        return;
    }
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

/// Block-only selection with no log/transaction filter. HyperSync returns rows
/// only for matching selections, so without `include_all_blocks` the response is
/// empty — this guards the regression where `envio data block.<field>` returned
/// nothing.
#[test]
fn block_only_selection_returns_block_data() {
    if skip_without_token() {
        return;
    }
    let out = envio_data(&[
        "block.number",
        "block.gasUsed",
        "--chain=1",
        "--where={ block: { number: { _gte: 20000000, _lte: 20000000 } } }",
    ]);
    assert!(out.ok, "envio data failed:\n{out}");

    assert_eq!(
        out.stdout,
        "\
blocks[1]{number,gasUsed}:
  20000000,11089692
",
        "unexpected stdout:\n{out}",
    );

    assert_eq!(out.stderr_template(), "", "unexpected stderr:\n{out}");
}

/// Deterministic large range that hypersync cannot return in one batch.
/// Verifies the executor prints the "next page" hint and echoes back the
/// original chain input plus the unchanged upper bound.
#[test]
fn paginates_when_range_exceeds_one_batch() {
    if skip_without_token() {
        return;
    }
    let out = envio_data(&[
        "block.number",
        "log.srcAddress",
        "--chain=1",
        "--where={ block: { number: { _gte: 18000000, _lte: 19000000 } }, log: { srcAddress: \"0xdAC17F958D2ee523a2206206994597C13D831ec7\" } }",
    ]);
    assert!(out.ok, "envio data failed:\n{out}");

    let expected = [
        "Got a response up to block <N>. To get the next page, run the following command:",
        "  envio data block.number log.srcAddress \\",
        "    --chain=<N> \\",
        "    --where='{ block: { number: { _gte: <N>, _lte: <N> } }, log: { srcAddress: \"0xdAC17F958D2ee523a2206206994597C13D831ec7\" } }'",
    ]
    .join("\n");
    assert_eq!(out.stderr_template(), expected, "unexpected stderr:\n{out}");
}
