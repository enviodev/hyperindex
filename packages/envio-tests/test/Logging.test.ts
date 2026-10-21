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
      // Pins the pretty format's colors, which otherwise follow the terminal.
      FORCE_COLOR: "1",
    },
    cwd: process.cwd(),
  });
};

const testLogStrategy = (strategy: string) => {
  it(`LOG_STRATEGY=${strategy}`, () => {
    const output = runWithStrategy(strategy);
    const snapshotPath = path.join(SNAPSHOTS_DIR, `Logging.${strategy}.snap`);
    const expected = readFileSync(snapshotPath, "utf-8");
    assert.equal(normalize(output), normalize(expected));
  });
};

describe("Logging Output", () => {
  testLogStrategy("console-pretty");
  testLogStrategy("console-raw");
  testLogStrategy("ecs-console");
});

// Node queues a write a full pipe can't take yet, while the logger writes
// synchronously, so a `console.log` writing stdout itself would be overtaken
// and split by the logger's lines; routed through the logger, it can't be.
describe("Logging Output (shared with console.log)", () => {
  it("keeps lines whole and in call order on a piped stdout", () => {
    const output = execSync("node test/fixtures/ConsoleOrder.res.mjs", {
      encoding: "utf-8",
      env: { ...process.env, ENVIO_TEST_LOGGING_FORMAT: "1" },
      maxBuffer: 1 << 26,
    });
    const lines = output
      .trimEnd()
      .split("\n")
      .map((line) => JSON.parse(line).message.split(" ").slice(0, 2).join(" "));
    assert.deepEqual(
      lines,
      Array.from({ length: 50 }, (_, i) => [`console ${i}`, `logger ${i}`]).flat()
    );
  });
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
    assert.equal(normalize(output), normalize(expected));
  });
});
