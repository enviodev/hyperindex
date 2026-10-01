// Clones each subgraph in corpus.json at its pinned commit, installs it the way
// its authors do, and indexes a window of blocks with this checkout's envio.
// That is the path a user takes, so what breaks here breaks for them first.
//
//   node scenarios/subgraph_corpus/run.mjs [name…]
//
// Needs network access and ENVIO_API_TOKEN for HyperSync.
import { execFileSync } from "node:child_process";
import { appendFileSync, existsSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const envio = path.resolve(here, "../../packages/envio");
const corpus = JSON.parse(readFileSync(path.join(here, "corpus.json"), "utf8"));
const only = process.argv.slice(2);

const run = (cwd, command, args) =>
  execFileSync(command, args, {
    cwd,
    stdio: "inherit",
    env: { ...process.env, COREPACK_ENABLE_DOWNLOAD_PROMPT: "0" },
  });

// Corepack runs the package manager version a project pins in `packageManager`.
function install(dir) {
  const { packageManager = "" } = JSON.parse(readFileSync(path.join(dir, "package.json"), "utf8"));
  const has = (file) => existsSync(path.join(dir, file));
  const manager =
    packageManager.split("@")[0] || (has("yarn.lock") ? "yarn" : has("pnpm-lock.yaml") ? "pnpm" : "npm");
  const yarnBerry = manager === "yarn" && /^yarn@[2-9]/.test(packageManager);
  const args = {
    yarn: yarnBerry
      ? ["install", "--immutable", "--mode=skip-build"]
      : ["install", "--frozen-lockfile", "--ignore-scripts"],
    pnpm: ["install", "--frozen-lockfile", "--ignore-scripts"],
    npm: ["install", "--ignore-scripts"],
  }[manager];
  if (manager === "npm") run(dir, "npm", args);
  else run(dir, "corepack", [manager, ...args]);
}

// What a test of the user's own would do: index from where the subgraph starts
// — its mappings assume every earlier entity exists — up to the entry's block.
const INDEX = `
import { createTestIndexer } from "envio";
const [chainId, endBlock] = process.argv.slice(2).map(Number);
await createTestIndexer().process({ chains: { [chainId]: { endBlock } } });
`;

const results = [];
for (const entry of corpus) {
  if (only.length > 0 && !only.includes(entry.name)) continue;
  const dir = mkdtempSync(path.join(tmpdir(), `envio-corpus-${entry.name}-`));
  console.log(`\n=== ${entry.name} (${entry.repo} @ ${entry.commit.slice(0, 8)})`);
  try {
    run(dir, "git", ["init", "--quiet"]);
    run(dir, "git", ["fetch", "--quiet", "--depth", "1", entry.repo, entry.commit]);
    run(dir, "git", ["checkout", "--quiet", "FETCH_HEAD"]);
    install(dir);
    rmSync(path.join(dir, "node_modules", "envio"), { recursive: true, force: true });
    symlinkSync(envio, path.join(dir, "node_modules", "envio"));
    writeFileSync(path.join(dir, ".envio-corpus.mjs"), INDEX);
    run(dir, process.execPath, [".envio-corpus.mjs", String(entry.chainId), String(entry.endBlock)]);
    results.push({ name: entry.name, ok: true });
  } catch (error) {
    results.push({ name: entry.name, ok: false, error: String(error.message).split("\n")[0] });
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

const summary = [
  "| subgraph | result |",
  "| --- | --- |",
  ...results.map(({ name, ok, error }) => `| ${name} | ${ok ? "✅" : `❌ ${error}`} |`),
].join("\n");
console.log(`\n${summary}`);
if (process.env.GITHUB_STEP_SUMMARY) appendFileSync(process.env.GITHUB_STEP_SUMMARY, `${summary}\n`);
process.exit(results.every(({ ok }) => ok) ? 0 : 1);
