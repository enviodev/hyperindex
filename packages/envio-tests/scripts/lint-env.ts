// The environment is read once, where the indexer starts, into its config.
// Logic below that reads the config, so a value can't change between two
// modules reading it, and a test sets it by passing config rather than by
// mutating the process.

import { readdirSync, readFileSync, statSync } from "node:fs";
import { join, relative } from "node:path";
import { fileURLToPath } from "node:url";

const srcRoot = fileURLToPath(new URL("../../envio/src", import.meta.url));
const repoRoot = fileURLToPath(new URL("../../../", import.meta.url));

// Where reading the environment belongs: the module that reads it, and the
// entry points that turn it into config.
const entryPoints = new Set([
  "Env.res",
  "EnvSafe.res",
  "Config.res",
  "Bin.res",
  "Worker.res",
  "TestIndexer.res",
  // Finds the native addon before anything else runs.
  "Core.res",
]);

// Modules that still read the environment themselves. Each moves its reads
// into config; the list only shrinks, so a file that stops reading the
// environment has to leave it.
const notYetMigrated = new Set([
  "CrossChainState.res",
  "Envio.res",
  "IndexerState.res",
  "PruneStaleHistory.res",
  "Server.res",
  "Storage.res",
  "Supervisor.res",
  "Writing.res",
  "bindings/ClickHouse.res",
  "tui/InitApi.res",
  "tui/Tui.res",
]);

const reads = /\bEnv\.|\bEnvSafe\.|process\.env|Process\.process\.env|dotenv/;

const files = (dir: string): string[] =>
  readdirSync(dir).flatMap((name) => {
    const path = join(dir, name);
    return statSync(path).isDirectory() ? files(path) : name.endsWith(".res") ? [path] : [];
  });

type violation = { file: string; line: number; title: string; fix: string };
const violations: violation[] = [];

for (const path of files(srcRoot)) {
  const file = relative(srcRoot, path);
  const lines = readFileSync(path, "utf8").split("\n");
  const readLines = lines.flatMap((line, index) =>
    reads.test(line.replace(/(?<!:)\/\/.*$/, "")) ? [index + 1] : [],
  );
  if (entryPoints.has(file)) continue;
  if (notYetMigrated.has(file)) {
    if (readLines.length === 0) {
      violations.push({
        file,
        line: 1,
        title: "No longer reads the environment",
        fix: `Remove "${file}" from notYetMigrated in packages/envio-tests/scripts/lint-env.ts.`,
      });
    }
    continue;
  }
  for (const line of readLines) {
    violations.push({
      file,
      line,
      title: "Reads the environment outside the indexer's entry",
      fix: "Read it in Env.res, put it on the config where the indexer starts (Config.fromPublic), and read it from there.",
    });
  }
}

for (const { file, line, title, fix } of violations) {
  const path = relative(repoRoot, join(srcRoot, file));
  console.log(`::error file=${path},line=${line},title=${title}::${fix}`);
}
if (violations.length > 0) {
  console.error(`${violations.length} environment read(s) outside the indexer's entry.`);
  process.exit(1);
}
