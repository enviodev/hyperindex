// The environment is read once, by Rust, into the indexer's config. Logic
// reads the config, so a value can't change between two modules reading it.

import { readdirSync, readFileSync, statSync } from "node:fs";
import { join, relative } from "node:path";
import { fileURLToPath } from "node:url";

const srcRoot = fileURLToPath(new URL("../../envio/src", import.meta.url));
const repoRoot = fileURLToPath(new URL("../../../", import.meta.url));

// Rust reads the environment (`indexer_env.rs`) and hands it over as
// `IndexerEnv.t` on the config. The only modules that touch `process.env` are
// the ones that move it between processes, never ones that read a value.
const allowed = new Set([
  // Finds and loads the native addon, before there is any Rust to ask.
  "Core.res",
  // Loads .env into the process, where Rust and user handlers read it.
  "IndexerEnv.res",
  // Puts the variables the CLI resolved into the process its workers inherit.
  "Bin.res",
  // Hands the process environment to the workers it forks.
  "run/Supervisor.res",
]);

const reads = /process\.env|dotenv/;

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
  if (allowed.has(file)) continue;
  for (const line of readLines) {
    violations.push({
      file,
      line,
      title: "Reads the environment in ReScript",
      fix: "Read it in packages/cli/src/indexer_env.rs, add it to IndexerEnv.t, and read it from config.env.",
    });
  }
}

for (const { file, line, title, fix } of violations) {
  const path = relative(repoRoot, join(srcRoot, file));
  console.log(`::error file=${path},line=${line},title=${title}::${fix}`);
}
if (violations.length > 0) {
  console.error(`${violations.length} environment read(s) in ReScript.`);
  process.exit(1);
}
