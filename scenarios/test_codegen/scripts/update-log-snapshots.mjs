#!/usr/bin/env node
import { execSync } from "child_process";
import { writeFileSync, mkdirSync } from "fs";
import { dirname } from "path";

const FIXTURE_PATH = "test/fixtures/LogTesting.res.mjs";
const SNAPSHOTS_DIR = "test/__snapshots__";

// Strategies that output to stdout
const strategies = [
  "console-pretty",
  "console-raw",
  "ecs-console",
  "both-prettyconsole",
];

// Normalize output by replacing timestamps and PIDs with placeholders
const normalize = (s) =>
  s
    // Pretty format: [HH:MM:SS.mmm]
    .replace(/\[\d{2}:\d{2}:\d{2}\.\d{3}\]/g, "[HH:MM:SS.mmm]")
    // Pretty format: (PID)
    .replace(/\(\d+\)/g, "(PID)")
    // ECS/JSON format: "process.pid":12345
    .replace(/"process\.pid":\d+/g, '"process.pid":PID')
    // ECS/JSON format: "@timestamp":"2026-01-05T12:54:45.274Z"
    .replace(/"@timestamp":"[^"]+"/g, '"@timestamp":"TIMESTAMP"');

// Ensure snapshots directory exists
mkdirSync(SNAPSHOTS_DIR, { recursive: true });

for (const strategy of strategies) {
  console.log(`Updating snapshot for ${strategy}...`);
  const output = execSync(`node ${FIXTURE_PATH}`, {
    encoding: "utf-8",
    env: {
      ...process.env,
      LOG_STRATEGY: strategy,
      LOGGING_TEST_RUNNER: "1",
    },
  });
  const snapshotPath = `${SNAPSHOTS_DIR}/Logging.${strategy}.snap`;
  writeFileSync(snapshotPath, normalize(output));
  console.log(`  Written to ${snapshotPath}`);
}

console.log("\nAll snapshots updated!");
