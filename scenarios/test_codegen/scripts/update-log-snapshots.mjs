#!/usr/bin/env node
import { execFileSync } from "child_process";
import { writeFileSync, mkdirSync } from "fs";

const FIXTURE_PATH = "test/fixtures/LogTesting.res.mjs";
const SNAPSHOTS_DIR = "test/__snapshots__";

// Strategies that output to stdout
const strategies = [
  "console-pretty",
  "console-raw",
  "ecs-console",
  "both-prettyconsole",
];

// Normalize output by replacing timestamps with placeholders
const normalize = (s) =>
  s
    // Pretty format: [HH:MM:SS.mmm]
    .replace(/\[\d{2}:\d{2}:\d{2}\.\d{3}\]/g, "[HH:MM:SS.mmm]")
    // ECS/JSON format: "@timestamp":"2026-01-05T12:54:45.274Z"
    .replace(/"@timestamp":"[^"]+"/g, '"@timestamp":"TIMESTAMP"');

// Ensure snapshots directory exists
mkdirSync(SNAPSHOTS_DIR, { recursive: true });

for (const strategy of strategies) {
  console.log(`Updating snapshot for ${strategy}...`);
  const output = execFileSync("node", [FIXTURE_PATH], {
    encoding: "utf-8",
    env: {
      ...process.env,
      LOG_STRATEGY: strategy,
      ENVIO_TEST_LOGGING_FORMAT: "1",
    },
  });
  const snapshotPath = `${SNAPSHOTS_DIR}/Logging.${strategy}.snap`;
  writeFileSync(snapshotPath, normalize(output));
  console.log(`  Written to ${snapshotPath}`);
}

console.log("\nAll snapshots updated!");
