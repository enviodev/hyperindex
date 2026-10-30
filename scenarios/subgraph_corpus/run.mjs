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
import { appendFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
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

// A window indexes in minutes; past this it hangs (a node that never answers).
const ENTRY_TIMEOUT_MS = 20 * 60 * 1000;

// The indexer runs as a child so the fixture RPC, served from this process,
// can answer it; a miss stops it rather than letting it retry forever.
function index(dir, entry, rpc) {
  const child = spawn(process.execPath, [".envio-corpus.mjs", String(entry.chainId), String(entry.endBlock)], {
    cwd: dir,
    stdio: "inherit",
    env: { ...process.env, ...(rpc ? { ENVIO_SUBGRAPH_RPC: rpc.url } : {}), ...entry.env },
  });
  const watch = setInterval(() => {
    if (rpc?.misses.length) child.kill();
  }, 200);
  let timedOut = false;
  const deadline = setTimeout(() => {
    timedOut = true;
    child.kill();
  }, ENTRY_TIMEOUT_MS);
  return new Promise((resolve, reject) => {
    child.on("exit", (code) => {
      clearInterval(watch);
      clearTimeout(deadline);
      if (rpc?.misses.length) reject(new Error(`no answer for ${rpc.misses[0]}`));
      else if (timedOut) {
        const stats = rpc?.upstreamStats?.();
        const node = stats
          ? ` (the node answered ${stats.answered} requests, failed ${JSON.stringify(stats.failed)})`
          : "";
        reject(new Error(`indexing took over ${ENTRY_TIMEOUT_MS / 60000} minutes${node}`));
      }
      else if (code !== 0) reject(new Error(`indexing exited with code ${code}`));
      else {
        const { changes } = JSON.parse(readFileSync(path.join(dir, RESULT), "utf8"));
        if (changes === 0) reject(new Error("indexing wrote no entity"));
        else resolve(changes);
      }
    });
  });
}

async function fixtureRpc(entry, dir) {
  const file = path.join(here, "fixtures", `${entry.name}.json`);
  if (!record) {
    if (existsSync(file)) return startRpcFixture({ chainId: entry.chainId, file });
    return startRpcFixture({ chainId: entry.chainId, fake: fakeCallAnswers(dir) });
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
// A window that indexes nothing (a wrong network or start block, handlers that
// never fire) would exit cleanly too, so it reports the checkpoints it wrote.
const RESULT = ".envio-corpus-result.json";
const INDEX = `
import { writeFileSync } from "node:fs";
import { createTestIndexer } from "envio";
const [chainId, endBlock] = process.argv.slice(2).map(Number);
const { changes } = await createTestIndexer().process({ chains: { [chainId]: { endBlock } } });
writeFileSync("${RESULT}", JSON.stringify({ changes: changes.length }));
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
    mkdirSync(path.join(dir, "node_modules"), { recursive: true });
    rmSync(path.join(dir, "node_modules", "envio"), { recursive: true, force: true });
    symlinkSync(envio, path.join(dir, "node_modules", "envio"));
    writeFileSync(path.join(dir, ".envio-corpus.mjs"), INDEX);
    const rpc = await fixtureRpc(entry, dir);
    let changes;
    try {
      changes = await index(dir, entry, rpc);
    } finally {
      await rpc?.close();
    }
    results.push({ name: entry.name, ok: true, changes, fake: rpc?.synthesized?.() ?? 0 });
  } catch (error) {
    results.push({ name: entry.name, ok: false, error: String(error.message).split("\n")[0] });
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

const summary = [
  "| subgraph | result |",
  "| --- | --- |",
  ...results.map(({ name, ok, changes, fake, error }) =>
    ok
      ? `| ${name} | ✅ ${changes} checkpoints written${fake > 0 ? `, ${fake} synthetic RPC answers` : ""} |`
      : `| ${name} | ❌ ${error} |`,
  ),
].join("\n");
console.log(`\n${summary}`);
if (process.env.GITHUB_STEP_SUMMARY) appendFileSync(process.env.GITHUB_STEP_SUMMARY, `${summary}\n`);
if (results.length === 0) console.error(`No corpus entry is named ${only.join(", ")}.`);
process.exit(results.length > 0 && results.every(({ ok }) => ok) ? 0 : 1);
