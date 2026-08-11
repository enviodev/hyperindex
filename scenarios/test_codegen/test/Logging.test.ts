import { execSync } from "child_process";
import { readFileSync } from "fs";
import { strict as assert } from "assert";
import path from "path";
import { describe, it, vi } from "vitest";

// Every case here boots a fresh node process, and the suite now runs a worker
// per core — so these wait on process startup against a fully loaded machine,
// not on anything they measure. The default 30s is sized for in-process tests.
vi.setConfig({ testTimeout: 120_000 });

const FIXTURE_PATH = "test/fixtures/LogTesting.res.mjs";
const SNAPSHOTS_DIR = path.join(import.meta.dirname, "__snapshots__");

// Normalize output by replacing timestamps with placeholders
const normalize = (s: string) =>
  s
    // Pretty format: [HH:MM:SS.mmm]
    .replace(/\[\d{2}:\d{2}:\d{2}\.\d{3}\]/g, "[HH:MM:SS.mmm]")
    // ECS/JSON format: "@timestamp":"2026-01-05T12:54:45.274Z"
    .replace(/"@timestamp":"[^"]+"/g, '"@timestamp":"TIMESTAMP"');

const runWithStrategy = (strategy: string): string => {
  return execSync(`node ${FIXTURE_PATH}`, {
    encoding: "utf-8",
    env: {
      ...process.env,
      LOG_STRATEGY: strategy,
      ENVIO_TEST_LOGGING_FORMAT: "1",
    },
    cwd: process.cwd(),
  });
};

// pino writes through worker threads, so the order in which two statements
// reach stdout isn't guaranteed once the machine is busy — both the pretty and
// the ECS transport have been seen interleaving under load. Compare the lines
// as a multiset instead: a missing, extra or altered line still fails, only
// their relative order is allowed to differ.
const sortLines = (s: string) => s.split("\n").sort().join("\n");
const compare = (s: string) => sortLines(normalize(s));

const testLogStrategy = (strategy: string) => {
  it(`LOG_STRATEGY=${strategy}`, () => {
    const output = runWithStrategy(strategy);
    const snapshotPath = path.join(SNAPSHOTS_DIR, `Logging.${strategy}.snap`);
    const expected = readFileSync(snapshotPath, "utf-8");
    assert.equal(compare(output), compare(expected));
  });
};

describe("Logging Output", () => {
  testLogStrategy("console-pretty");
  testLogStrategy("console-raw");
  testLogStrategy("ecs-console");
});

// These strategies write to file, not stdout - test separately
describe("Logging Output (file strategies)", () => {
  it("LOG_STRATEGY=ecs-file writes to log file", () => {
    // This strategy writes to file, stdout should be empty
    const output = runWithStrategy("ecs-file");
    assert.equal(output.trim(), "");
  });

  it("LOG_STRATEGY=file-only writes to log file", () => {
    const output = runWithStrategy("file-only");
    assert.equal(output.trim(), "");
  });

  it("LOG_STRATEGY=both-prettyconsole writes to both", () => {
    const output = runWithStrategy("both-prettyconsole");
    const snapshotPath = path.join(
      SNAPSHOTS_DIR,
      "Logging.both-prettyconsole.snap"
    );
    const expected = readFileSync(snapshotPath, "utf-8");
    assert.equal(compare(output), compare(expected));
  });
});
