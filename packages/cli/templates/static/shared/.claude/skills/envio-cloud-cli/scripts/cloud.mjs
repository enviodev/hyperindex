#!/usr/bin/env node
// Helper for the envio-cloud-cli skill. Run `node cloud.mjs help` for usage.
//
// Exit codes: 0 done, 1 failed (the output says why), 2 usage error,
// 75 still in progress when the time budget ran out: run the same command again.

import { spawnSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";

const IN_PROGRESS = 75;

const usage = `Usage:
  node cloud.mjs check [root-dir]
      Checks an indexer directory for what makes Envio Cloud reject or fail a build.
  node cloud.mjs wait-commit <indexer> <commit> <org> [--deploy] [--timeout <s>]
      Waits until Envio Cloud has seen <commit> and reports its status.
      --deploy deploys it when it is 'inactive' (auto-deploy off) and waits for it to start.
  node cloud.mjs wait-synced <indexer> <commit> <org> [--timeout <s>]
      Waits until every chain has caught up, then prints the GraphQL endpoint and checks it answers.

Time budget defaults to 540 s, under a 10-minute tool call limit. Exit code 75 means
"still in progress": run the same command again. The envio-cloud command defaults to
"npx -y envio-cloud"; override it with ENVIO_CLOUD_CLI.`;

const COMMIT_STATUS = {
  pending: { wait: true, meaning: "Envio Cloud is still processing the commit" },
  deploy: { wait: true, meaning: "a deployment of this commit is starting" },
  active: { done: true, meaning: "the commit has a deployment" },
  inactive: {
    meaning:
      "not deployed: auto-deploy is off, or the indexer hit its plan's deployment (3 per indexer) or indexing-hour limit",
    fix: "deploy it with --deploy, or delete an old deployment first if the indexer already has 3",
  },
  deletingDeploymemt: { meaning: "the commit's deployment is being deleted", fix: "push a new commit" },
  configFileMissing: {
    meaning: "the config file was not found",
    fix: "check --root-dir and --config-file with `indexer settings get`; the config path is relative to the root dir",
  },
  packageJsonMissing: {
    meaning: "package.json was not found in the indexer's root dir",
    fix: "check --root-dir with `indexer settings get`",
  },
  failedToDownload: {
    meaning: "Envio Cloud could not download the commit from GitHub",
    fix: "check the root dir and that the Envio Deployments GitHub App can access the repo, then push a new commit",
  },
  versionNotSupported: {
    meaning: "the envio version in package.json is not supported",
    fix: 'pin an exact version (e.g. "envio": "3.0.0"), at least 2.21.5 and not 2.29.x; ranges, latest and workspace:* are rejected',
  },
  clickhouseConfigMismatch: {
    meaning: "storage.clickhouse in config.yaml doesn't match the indexer's setup",
    fix: "align storage.clickhouse with the indexer's plan or contact Envio",
  },
  clickhouseVersionNotSupported: {
    meaning: "ClickHouse needs envio 3.0.2 or newer",
    fix: "upgrade envio in package.json",
  },
  reorgsEnabled: {
    meaning: "rollback_on_reorg was on, which the plan didn't allow when the commit was processed",
    fix: "push a new commit; if it's rejected again, ask the user whether to set rollback_on_reorg: false or upgrade the plan",
  },
};

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

function parseArgs(argv) {
  const positional = [];
  const flags = {};
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === "--deploy") flags.deploy = true;
    else if (arg === "--timeout") flags.timeout = argv[++i];
    else positional.push(arg);
  }
  return { positional, flags };
}

function cloud(args) {
  const [cmd, ...base] = (process.env.ENVIO_CLOUD_CLI || "npx -y envio-cloud").split(" ");
  const result = spawnSync(cmd, [...base, ...args], { encoding: "utf8" });
  return { code: result.status ?? 1, stdout: result.stdout ?? "", stderr: result.stderr ?? "" };
}

// Envio Cloud's JSON envelope is {"ok": true, "data": ...} or {"ok": false, "error": "..."}.
// Some failures print only to stderr, so a non-zero exit or unparsable stdout counts as an error.
function cloudJson(args) {
  const { code, stdout, stderr } = cloud([...args, "-o", "json"]);
  let parsed;
  try {
    parsed = JSON.parse(stdout);
  } catch {
    return { error: (stderr || stdout).trim() || `exit code ${code}` };
  }
  if (code !== 0 || parsed.ok === false) {
    return { error: parsed.error || stderr.trim() || `exit code ${code}` };
  }
  return { data: parsed.data };
}

function failOnAuth(error) {
  if (/not logged in|session expired|login/i.test(error)) {
    console.log(`Not logged in to Envio Cloud: ${error}`);
    console.log("Log in first (SKILL.md, recipe 1), then run this again.");
    process.exit(1);
  }
}

const sameCommit = (a, b) => a.startsWith(b) || b.startsWith(a);

async function waitCommit([indexer, commit, org], flags) {
  if (!indexer || !commit || !org) return usageError();
  const deadline = Date.now() + Number(flags.timeout ?? 540) * 1000;
  let deployed = false;
  let lastLine = "";
  while (true) {
    const { data, error } = cloudJson(["indexer", "commits", indexer, org, "--limit", "20"]);
    if (error) failOnAuth(error);
    const commits = Array.isArray(data) ? data : data?.commits ?? [];
    const found = commits.find((c) => c.commit_hash && sameCommit(c.commit_hash, commit));
    const status = found?.status;
    const line = error
      ? `envio-cloud error: ${error}`
      : found
        ? `${commit}: ${status} (${COMMIT_STATUS[status]?.meaning ?? "unknown status"})`
        : `${commit}: not seen by Envio Cloud yet`;
    if (line !== lastLine) console.log(line);
    lastLine = line;

    const info = COMMIT_STATUS[status];
    if (info?.done) {
      console.log(`Done. Next: node cloud.mjs wait-synced ${indexer} ${commit} ${org}`);
      return 0;
    }
    if (status === "inactive" && flags.deploy && !deployed) {
      const result = cloud(["deployment", "deploy", indexer, found.commit_hash, org, "--yes"]);
      console.log((result.stdout + result.stderr).trim());
      if (result.code !== 0) return 1;
      deployed = true;
    } else if (found && !info?.wait && !(status === "inactive" && deployed)) {
      console.log(info?.fix ? `Fix: ${info.fix}` : "See the commit statuses table in reference.md.");
      return 1;
    }
    if (Date.now() > deadline) {
      if (deployed && status === "inactive") {
        // Envio Cloud can accept a deploy without starting one, e.g. when the commit's code is gone.
        console.log("The deploy was accepted but nothing started. Push a new commit to the branch (an empty one works).");
        return 1;
      }
      if (!found) {
        console.log(
          "Envio Cloud only sees commits pushed to the indexer's branch after the indexer was added. " +
            "Check `indexer settings get` for the branch and `repos` for the repo link.",
        );
      }
      console.log("Still in progress: run the same command again.");
      return IN_PROGRESS;
    }
    await sleep(Number(process.env.CLOUD_POLL_MS ?? 10_000));
  }
}

function chainLine(c) {
  const caughtUp = c.timestamp_caught_up_to_head_or_endblock || c.has_processed_to_end_block;
  const lag = Number(c.block_height) - Number(c.latest_processed_block);
  return {
    caughtUp: Boolean(caughtUp) || lag <= 0,
    text: `chain ${c.chain_id}: ${c.latest_processed_block}/${c.block_height}${caughtUp ? " (caught up)" : ` (${lag} behind)`}`,
  };
}

async function checkEndpoint(indexer, commit, org) {
  const { code, stdout, stderr } = cloud(["deployment", "endpoint", indexer, commit, org, "-q"]);
  const url = stdout.trim().split("\n").pop();
  if (code !== 0 || !url?.startsWith("http")) {
    console.log(`No endpoint yet: ${(stderr || stdout).trim()}`);
    return;
  }
  console.log(`GraphQL endpoint (this deployment): ${url}`);
  try {
    const response = await fetch(url, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ query: "{ _meta { isReady progressBlock } }" }),
    });
    console.log(`_meta query: HTTP ${response.status} ${(await response.text()).slice(0, 300)}`);
  } catch (e) {
    console.log(`_meta query failed: ${e.message}`);
  }
}

async function waitSynced([indexer, commit, org], flags) {
  if (!indexer || !commit || !org) return usageError();
  const deadline = Date.now() + Number(flags.timeout ?? 540) * 1000;
  while (true) {
    const { data, error } = cloudJson(["deployment", "status", indexer, commit, org]);
    if (error) failOnAuth(error);
    const chains = Array.isArray(data) ? data.map(chainLine) : [];
    if (chains.length === 0) {
      console.log(error ? `No sync metrics yet: ${error}` : "No sync metrics yet (still building?)");
    } else {
      console.log(chains.map((c) => c.text).join("\n"));
      if (chains.every((c) => c.caughtUp)) {
        console.log("Synced.");
        await checkEndpoint(indexer, commit, org);
        return 0;
      }
    }
    if (Date.now() > deadline) {
      if (chains.length === 0) {
        console.log(
          `No progress reported. Check the build: npx -y envio-cloud deployment logs ${indexer} ${commit} ${org} --build --level error`,
        );
      }
      console.log("Still in progress: run the same command again.");
      return IN_PROGRESS;
    }
    await sleep(Number(process.env.CLOUD_POLL_MS ?? 30_000));
  }
}

function check([rootDir = "."], flags) {
  const problems = [];
  const notes = [];
  const pkgPath = join(rootDir, "package.json");
  if (!existsSync(pkgPath)) {
    problems.push(`${pkgPath} not found: Envio Cloud builds from the indexer's root dir (--root-dir)`);
  } else {
    const pkg = JSON.parse(readFileSync(pkgPath, "utf8"));
    const version = pkg.dependencies?.envio ?? pkg.devDependencies?.envio;
    if (!version) problems.push('package.json has no "envio" dependency');
    else if (!/^\d+\.\d+\.\d+(-[\w.]+)?$/.test(version)) {
      problems.push(`"envio": "${version}" is not an exact version; Envio Cloud rejects ranges, latest and workspace:*`);
    } else {
      const [major, minor, patch] = version.split(/[.-]/).map(Number);
      if (major === 2 && (minor < 21 || (minor === 21 && patch < 5))) {
        problems.push(`envio ${version} is older than 2.21.5, the minimum on Envio Cloud`);
      }
      if (major === 2 && minor === 29) problems.push(`envio 2.29.x is not supported on Envio Cloud`);
    }
    notes.push("Envio Cloud ignores your lockfile and resolves dependency ranges fresh: pin exact versions if a build differs from local.");
  }

  const configPath = ["config.yaml", "config.yml"].map((f) => join(rootDir, f)).find(existsSync);
  if (!configPath) {
    problems.push(`no config.yaml in ${rootDir}; pass --config-file if it has another name`);
  } else {
    const config = readFileSync(configPath, "utf8");
    for (const match of config.matchAll(/^\s*(?:abi_file_path|handler|schema):\s*(\S+)/gm)) {
      const path = match[1].replace(/["']/g, "").replace(/^\.\//, "");
      if (path.startsWith("../")) {
        problems.push(`${path} is outside the root dir, which is the only folder uploaded`);
      } else if (/(^|\/)(generated|node_modules)\//.test(path) || /(^|\/)\.(?!envio\/)[^/]+\//.test(path)) {
        problems.push(`${path} is in a folder Envio Cloud skips (generated, node_modules, dot folders other than .envio)`);
      }
    }
  }

  const git = (...args) => spawnSync("git", ["-C", rootDir, ...args], { encoding: "utf8" });
  const dirty = git("status", "--porcelain", "--", ".").stdout.trim();
  if (dirty) problems.push(`uncommitted changes in ${rootDir}: Envio Cloud builds only what is pushed`);
  const unpushed = git("log", "--oneline", "@{u}..HEAD");
  if (unpushed.status === 0 && unpushed.stdout.trim()) {
    notes.push("local commits not pushed yet: Envio Cloud sees only pushed commits");
  }

  for (const note of notes) console.log(`note: ${note}`);
  for (const problem of problems) console.log(`problem: ${problem}`);
  console.log(problems.length ? `${problems.length} problem(s) to fix before deploying.` : "No problems found.");
  return problems.length ? 1 : 0;
}

function usageError() {
  console.log(usage);
  return 2;
}

const [command, ...rest] = process.argv.slice(2);
const { positional, flags } = parseArgs(rest);
const commands = { check, "wait-commit": waitCommit, "wait-synced": waitSynced };
const run = commands[command];
process.exit(run ? await run(positional, flags) : command === "help" ? (console.log(usage), 0) : usageError());
