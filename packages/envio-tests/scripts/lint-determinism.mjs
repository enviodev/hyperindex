// A test that drives the indexer loop can't wait on `Utils.delay(0)`: the count
// of ticks is a guess at how many await hops the loop needs to reach the next
// observable state. The guess is unwritable without trial and error, breaks
// whenever production code gains an await, and — worse — makes a negative
// assertion pass vacuously when it comes up short. `indexer.settle()` and its
// condition-based peers wait on the loop's own in-flight count instead.
//
// The ban is on every test by default. A unit test that never builds an indexer
// has no loop to settle and means the tick literally, so it opts out by name
// with the marker below — one line that says which kind of test it is, rather
// than a pattern that quietly stops matching when a test moves its body into a
// helper. The opt-out is checked against the file it sits in: the day such a
// file grows a test that does drive an indexer, the marker is refused rather
// than quietly covering it.

import { readdirSync, readFileSync } from "node:fs";
import { join, relative } from "node:path";
import { fileURLToPath } from "node:url";

const testRoot = fileURLToPath(new URL("../test", import.meta.url));

// Scanned over the whole file rather than line by line, so a call the
// formatter wrapped across lines is still caught.
const banned = /Utils\s*\.\s*delay\(\s*0\s*,?\s*\)/g;
const optOut = "determinism-lint: no indexer loop";
// The ways a test can come by an indexer. Deliberately module names rather
// than `indexer.`, which prose in a comment matches just as well.
const drivesAnIndexer = /\bIndexerRunner\.|\bScenario\.|\bInternalTestIndexer\.|\bcreateTestIndexer\b|\bIndexerLoop\.start\b/;

const resFiles = (dir) =>
  readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const path = join(dir, entry.name);
    if (entry.isDirectory()) return resFiles(path);
    return entry.isFile() && entry.name.endsWith(".res") ? [path] : [];
  });

const violations = [];
const staleOptOuts = [];
for (const path of resFiles(testRoot)) {
  const source = readFileSync(path, "utf8");
  if (source.includes(optOut)) {
    if (drivesAnIndexer.test(source)) {
      staleOptOuts.push(relative(process.cwd(), path));
    }
    continue;
  }
  for (const match of source.matchAll(banned)) {
    const line = source.slice(0, match.index).split("\n").length;
    violations.push(`${relative(process.cwd(), path)}:${line}: ${match[0].replace(/\s+/g, "")}`);
  }
}

if (staleOptOuts.length > 0) {
  console.error(
    [
      `These files claim "${optOut}" but build one:`,
      "",
      ...staleOptOuts,
      "",
      "Drop the marker and wait on the loop, or move the unit tests to a file of their own.",
    ].join("\n"),
  );
  process.exit(1);
}

if (violations.length > 0) {
  console.error(
    [
      "Utils.delay(0) counts ticks instead of waiting on the indexer:",
      "",
      ...violations,
      "",
      "Wait on the loop:",
      "  indexer.settle()                     — every scheduled step ran, nothing left but the outside world",
      "  indexer.settleUntil(cond, ~message)  — re-settles until a condition arrives on its own cadence",
      "  indexer.park(() => gate)             — a wait the test itself holds closed, so settle doesn't wait it out",
      "  Scenario.expectQueries(...)          — settles, then asserts the whole pending query set",
      "  Scenario.waitUntil(cond, ~message)   — for state only observable from outside the loop",
      "",
      `A unit test that never builds an indexer opts out with a comment: ${optOut}`,
    ].join("\n"),
  );
  process.exit(1);
}
