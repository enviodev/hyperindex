/**
 * Iteration helper: runs corpus cases against a running `envio serve`
 * instance and diffs them against the recorded Hasura oracle snapshots.
 * No Hasura needed.
 *
 * Usage: pnpm --filter e2e-tests exec tsx src/differential/diffServe.ts \
 *          [--phase default|limited] [--filter substr] [--verbose N]
 */

import { readFile } from "node:fs/promises";
import { allCases } from "./corpus/index.js";
import type { Phase } from "./corpus.js";
import { serveUrl } from "./env.js";
import { runCase, normalize, type GraphQLResponse } from "./runner.js";

const argv = process.argv.slice(2);
const arg = (name: string): string | undefined => {
  const i = argv.indexOf(name);
  return i >= 0 ? argv[i + 1] : undefined;
};

const phase = (arg("--phase") ?? "default") as Phase;
const filter = arg("--filter");
const verbose = Number(arg("--verbose") ?? 3);

const snapshotsDir = new URL(
  `../../fixtures/differential/snapshots/${phase}/`,
  import.meta.url
);

interface Snapshot {
  status: number;
  body: unknown;
}

function firstDiff(a: unknown, b: unknown, path = "$"): string | undefined {
  if (a === b) return undefined;
  if (
    typeof a !== typeof b ||
    a === null ||
    b === null ||
    typeof a !== "object"
  ) {
    return `${path}: oracle=${JSON.stringify(a)?.slice(0, 200)} serve=${JSON.stringify(b)?.slice(0, 200)}`;
  }
  if (Array.isArray(a) !== Array.isArray(b)) {
    return `${path}: array-vs-object mismatch`;
  }
  const ao = a as Record<string, unknown>;
  const bo = b as Record<string, unknown>;
  const keys = new Set([...Object.keys(ao), ...Object.keys(bo)]);
  for (const k of keys) {
    if (!(k in ao)) return `${path}.${k}: missing in oracle, serve has it`;
    if (!(k in bo)) return `${path}.${k}: present in oracle, missing in serve`;
    const d = firstDiff(ao[k], bo[k], `${path}.${k}`);
    if (d) return d;
  }
  return `${path}: objects differ in key order only? oracle=${JSON.stringify(ao).slice(0, 100)}`;
}

async function main() {
  const cases = allCases.filter(
    (c) =>
      (c.phases ?? ["default"]).includes(phase) &&
      (!filter || c.name.includes(filter))
  );

  let pass = 0;
  const failures: { name: string; detail: string }[] = [];

  for (const corpusCase of cases) {
    let oracle: Snapshot;
    try {
      oracle = JSON.parse(
        await readFile(new URL(`${corpusCase.name}.json`, snapshotsDir), "utf8")
      ) as Snapshot;
    } catch {
      failures.push({ name: corpusCase.name, detail: "no oracle snapshot" });
      continue;
    }
    let serve: GraphQLResponse;
    try {
      serve = await runCase(serveUrl, corpusCase);
    } catch (err) {
      failures.push({
        name: corpusCase.name,
        detail: `request failed: ${err instanceof Error ? err.message : err}`,
      });
      continue;
    }
    const nOracle = normalize(
      { status: oracle.status, body: oracle.body },
      corpusCase.compare
    );
    const nServe = normalize(serve, corpusCase.compare);
    if (JSON.stringify(nOracle) === JSON.stringify(nServe)) {
      pass++;
    } else {
      const detail =
        nOracle.status !== nServe.status
          ? `status: oracle=${nOracle.status} serve=${nServe.status} body=${JSON.stringify(nServe.body).slice(0, 200)}`
          : (firstDiff(nOracle.body, nServe.body) ?? "unknown diff");
      failures.push({ name: corpusCase.name, detail });
    }
  }

  console.log(`\n${pass}/${cases.length} passed (phase=${phase})`);
  if (failures.length > 0) {
    console.log(`\nFailures (${failures.length}):`);
    const byCategory = new Map<string, number>();
    for (const f of failures) {
      const cat = f.name.split("-")[0] ?? "?";
      byCategory.set(cat, (byCategory.get(cat) ?? 0) + 1);
    }
    console.log(
      "By category:",
      [...byCategory.entries()].map(([c, n]) => `${c}:${n}`).join(" ")
    );
    for (const f of failures.slice(0, verbose)) {
      console.log(`\n--- ${f.name}\n    ${f.detail}`);
    }
    if (failures.length > verbose) {
      console.log(
        `\n(${failures.length - verbose} more; use --verbose N or --filter)`
      );
      for (const f of failures.slice(verbose)) console.log(`  ${f.name}`);
    }
    process.exit(1);
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
