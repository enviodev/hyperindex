// Clones each subgraph in corpus.json at its pinned commit, installs it the way
// its authors do, and indexes a window of blocks with this checkout's envio.
// That is the path a user takes, so what breaks here breaks for them first.
//
//   node scenarios/subgraph_corpus/run.mjs [name…]
//
// Needs network access and ENVIO_API_TOKEN for HyperSync. Contract calls are
// answered from fixtures/<name>.json, or with synthetic values where an entry
// has none. CORPUS_RPC_RECORD=1 records fixtures instead, from an archive node
// per chain: ENVIO_SUBGRAPH_RPC_<chainId>, a URL.
import { execFileSync, spawn } from "node:child_process";
import { appendFileSync, existsSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { fakeCallAnswers } from "./fake-calls.mjs";
import { startRpcFixture } from "./rpc-fixture.mjs";

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

const record = process.env.CORPUS_RPC_RECORD === "1";

// The indexer runs as a child so the fixture RPC, served from this process,
// can answer it; a replay miss stops it rather than letting it retry forever.
function index(dir, entry, rpc) {
  const child = spawn(process.execPath, [".envio-corpus.mjs", String(entry.chainId), String(entry.endBlock)], {
    cwd: dir,
    stdio: "inherit",
    env: { ...process.env, ...(rpc ? { ENVIO_SUBGRAPH_RPC: rpc.url } : {}), ...entry.env },
  });
  const watch = setInterval(() => {
    if (rpc?.misses.length) child.kill();
  }, 200);
  return new Promise((resolve, reject) => {
    child.on("exit", (code) => {
      clearInterval(watch);
      if (rpc?.misses.length) reject(new Error(`no recorded answer for ${rpc.misses[0]}`));
      else if (code === 0) resolve();
      else reject(new Error(`indexing exited with code ${code}`));
    });
  });
}

async function fixtureRpc(entry, dir) {
  const file = path.join(here, "fixtures", `${entry.name}.json`);
  if (!record) {
    if (existsSync(file)) return startRpcFixture({ chainId: entry.chainId, file });
    return { ...(await startRpcFixture({ chainId: entry.chainId, fake: fakeCallAnswers(dir) })), fake: true };
  }
  const upstream = process.env[`ENVIO_SUBGRAPH_RPC_${entry.chainId}`];
  if (!upstream) throw new Error(`recording needs ENVIO_SUBGRAPH_RPC_${entry.chainId}`);
  return startRpcFixture({ chainId: entry.chainId, file, upstream });
}

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
    const rpc = await fixtureRpc(entry, dir);
    try {
      await index(dir, entry, rpc);
    } finally {
      await rpc?.close();
    }
    results.push({ name: entry.name, ok: true, fake: rpc?.fake });
  } catch (error) {
    results.push({ name: entry.name, ok: false, error: String(error.message).split("\n")[0] });
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

const summary = [
  "| subgraph | result |",
  "| --- | --- |",
  ...results.map(({ name, ok, fake, error }) => `| ${name} | ${ok ? (fake ? "✅ (synthetic contract calls)" : "✅") : `❌ ${error}`} |`),
].join("\n");
console.log(`\n${summary}`);
if (process.env.GITHUB_STEP_SUMMARY) appendFileSync(process.env.GITHUB_STEP_SUMMARY, `${summary}\n`);
process.exit(results.every(({ ok }) => ok) ? 0 : 1);
