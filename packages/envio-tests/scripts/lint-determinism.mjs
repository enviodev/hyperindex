// A scenario test drives a real indexer loop, so `Utils.delay(0)` there is a
// guess at how many await hops the loop needs to reach the next observable
// state. The guess is unwritable without trial and error, breaks whenever
// production code gains an await, and — worse — makes a negative assertion pass
// vacuously when it comes up short. `indexer.settle()` and its condition-based
// peers wait on the loop's own in-flight count instead.
//
// Unit tests that never build an indexer keep it: there is no loop to settle,
// and a tick is exactly what they mean.

import { readdirSync, readFileSync } from "node:fs";
import { join, relative } from "node:path";
import { fileURLToPath } from "node:url";

const testRoot = fileURLToPath(new URL("../test", import.meta.url));

const banned = /Utils\.delay\(0\)/;
// Files that reach for the scenario harness at all: they own an indexer, so
// they have something to settle.
const drivesAnIndexer = /\bIndexerRunner\.t\b|\bScenario\.(it|run)\b/;

const resFiles = (dir) =>
  readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const path = join(dir, entry.name);
    if (entry.isDirectory()) return resFiles(path);
    return entry.isFile() && entry.name.endsWith(".res") ? [path] : [];
  });

const violations = [];
for (const path of resFiles(testRoot)) {
  const source = readFileSync(path, "utf8");
  if (!drivesAnIndexer.test(source)) continue;
  source.split("\n").forEach((line, index) => {
    if (banned.test(line)) {
      violations.push(`${relative(process.cwd(), path)}:${index + 1}: ${line.trim()}`);
    }
  });
}

if (violations.length > 0) {
  console.error(
    [
      "Utils.delay(0) in a test that drives an indexer:",
      "",
      ...violations,
      "",
      "Wait on the loop instead of on ticks:",
      "  indexer.settle()                     — every scheduled step ran, nothing left but the outside world",
      "  indexer.settleUntil(cond, ~message)  — re-settles until a condition arrives on its own cadence",
      "  indexer.park(() => gate)             — a wait the test itself holds closed, so settle doesn't wait it out",
      "  Scenario.expectQueries(...)          — settles, then asserts the whole pending query set",
    ].join("\n"),
  );
  process.exit(1);
}
