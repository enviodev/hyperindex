// A test that waits for the indexer to ask the source by counting event-loop
// ticks (`await Utils.delay(0)`) or polling the pending queries guesses at how
// many await hops production code takes. The guess is unwritable without trial
// and error and breaks the day production code gains an await. It is also
// unnecessary: `expectItemsQueries` waits for the queries it names, and a height
// answer with no call pending is held for the next one.

import { readdirSync, readFileSync } from "node:fs";
import { join, relative } from "node:path";
import { fileURLToPath } from "node:url";

const testRoot = fileURLToPath(new URL("../test", import.meta.url));
// Paths are reported against the repo root rather than the cwd, so they mean the
// same thing whether this runs from the package, from the root, or from CI — and
// so GitHub can attach an annotation to the line.
const repoRoot = fileURLToPath(new URL("../../../", import.meta.url));

const delay = /^\s*(?:await\s+)?Utils\.delay\(0\)\s*$/;
const mockStep =
  /^\s*(?:await\s+)?(?:let\s+\S+\s*=\s*)?\S*\b(expectItemsQueries|expectBlockHashLookup|expectHeightCalls|respondEmptyUpTo|drainPendingItemsQueries|pendingItemsQueries|resolveGetHeightOrThrow|resolveInitialHeight|enterReorgThreshold)\b/;
const pollStart = /\b(while\b|waitUntil\()/;

// The scan has to reach the next statement past whatever sits between it and
// the delay. A comment that hid a violation would make the lint quietly useless.
const nextCodeLine = (lines: string[], start: number): string | null => {
  let inBlockComment = false;
  for (let index = start; index < lines.length; index++) {
    let rest = lines[index];
    let code = "";
    if (inBlockComment) {
      const close = rest.indexOf("*/");
      if (close === -1) continue;
      rest = rest.slice(close + 2);
      inBlockComment = false;
    }
    for (;;) {
      const open = rest.indexOf("/*");
      if (open === -1) {
        code += rest;
        break;
      }
      const close = rest.indexOf("*/", open + 2);
      if (close === -1) {
        code += rest.slice(0, open);
        inBlockComment = true;
        break;
      }
      code += rest.slice(0, open);
      rest = rest.slice(close + 2);
    }
    const trimmed = code.trim();
    if (trimmed === "" || trimmed.startsWith("//")) continue;
    return code;
  }
  return null;
};

const resFiles = (dir: string): string[] =>
  readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const path = join(dir, entry.name);
    if (entry.isDirectory()) return resFiles(path);
    return entry.isFile() && entry.name.endsWith(".res") ? [path] : [];
  });

type violation = { file: string; line: number; title: string; fix: string };

const violations: violation[] = [];
for (const path of resFiles(testRoot)) {
  const file = relative(repoRoot, path);
  const lines = readFileSync(path, "utf8").split("\n");
  lines.forEach((line, index) => {
    const code = line.replace(/\/\/.*$/, "");
    if (delay.test(code)) {
      const step = nextCodeLine(lines, index + 1)?.match(mockStep)?.[1];
      if (step) {
        violations.push({
          file,
          line: index + 1,
          title: `Utils.delay(0) before ${step}`,
          fix:
            step === "resolveGetHeightOrThrow"
              ? "Delete the delay: a height answer with no call pending is held for the next call."
              : `Delete the delay: \`${step}\` waits for what it answers, or answers only what is already pending.`,
        });
      }
    }
    // A poll's condition sits on the same line or the one after it. A loop that
    // steps a faked clock is moving time, which `expectItemsQueries` can't do.
    if (pollStart.test(code)) {
      const condition = `${code} ${nextCodeLine(lines, index + 1) ?? ""}`;
      const body = lines.slice(index, index + 8).join("\n");
      if (/\bpendingItemsQueries\b/.test(condition) && !/\badvanceTimers/.test(body)) {
        violations.push({
          file,
          line: index + 1,
          title: "Polling pendingItemsQueries",
          fix:
            "Replace the poll with `await mock.expectItemsQueries([...])` naming the queries " +
            "(`reply: LeavePending` for ones answered later).",
        });
      }
    }
  });
}

// A scenario on virtual time only moves when it advances its clock, so real
// time spent between steps changes nothing it can observe, and a count taken
// before a step stands in for what `expectNewHeightCalls` checks exactly.
const realDelay = /\bUtils\.delay\((\d+)\)/;
const pollSnapshot = /->\s*polls\b/;
const scenarioStart = /\bScenario\.(?:it|run)\(/;

// A scenario that shortens the source layer's windows on real time races its
// own steps on a loaded runner. Existing ones are counted per file and the
// count may only fall; a new one has to run on virtual time.
const baselinePath = fileURLToPath(new URL("./real-time-timing-baseline.json", import.meta.url));
const baseline: Record<string, number> = JSON.parse(readFileSync(baselinePath, "utf8"));
const realTimeTiming: Record<string, number[]> = {};

for (const path of resFiles(testRoot)) {
  const file = relative(repoRoot, path);
  const lines = readFileSync(path, "utf8").split("\n");
  const starts = lines.flatMap((line, index) => (scenarioStart.test(line) ? [index] : []));
  starts.forEach((start, position) => {
    const end = starts[position + 1] ?? lines.length;
    const block = lines.slice(start, end);
    const code = block.map((line) => line.replace(/\/\/.*$/, ""));
    if (code.some((line) => /~virtualTime=true\b/.test(line))) {
      code.forEach((line, offset) => {
        const delay = line.match(realDelay);
        if (delay && Number(delay[1]) > 0) {
          violations.push({
            file,
            line: start + offset + 1,
            title: `Utils.delay(${delay[1]}) on virtual time`,
            fix: `Replace it with \`await indexer.advanceTime(${delay[1]})\`: the source layer's timers only fire when the test advances the clock.`,
          });
        }
        if (/\bDate\.now\(/.test(line)) {
          violations.push({
            file,
            line: start + offset + 1,
            title: "Date.now() on virtual time",
            fix: "Time the scenario by how far it advanced: real time says nothing about when a virtual timer fired.",
          });
        }
        if (pollSnapshot.test(line)) {
          violations.push({
            file,
            line: start + offset + 1,
            title: "Counting height calls by hand on virtual time",
            fix: "Replace the count with `await mock.expectNewHeightCalls(n)` at the step that causes the polls.",
          });
        }
      });
    } else if (code.some((line) => /~sourceTiming=/.test(line))) {
      (realTimeTiming[file] ??= []).push(start + 1);
    }
  });
}

for (const file of new Set([...Object.keys(baseline), ...Object.keys(realTimeTiming)])) {
  const found = realTimeTiming[file] ?? [];
  const allowed = baseline[file] ?? 0;
  if (found.length > allowed) {
    violations.push({
      file,
      line: found[found.length - 1],
      title: `${found.length} real-time scenarios with ~sourceTiming, ${allowed} allowed`,
      fix: "Add `~virtualTime=true` to the new scenario and drive its timers with `await indexer.advanceTime(ms)`: a shortened window on real time races the test's own steps on a loaded runner.",
    });
  } else if (found.length < allowed) {
    violations.push({
      file,
      line: 1,
      title: `Fewer real-time scenarios with ~sourceTiming than the baseline`,
      fix: `Lower "${file}" in packages/envio-tests/scripts/real-time-timing-baseline.json to ${found.length}, so a later one can't take its place.`,
    });
  }
}

if (violations.length > 0) {
  // An annotation puts the rule on the line that broke it, in the PR diff. The log
  // alone is prose under a step named for the tests, which a reader reaches only
  // after scrolling past the service-container dumps that follow a failed job.
  if (process.env.GITHUB_ACTIONS) {
    for (const { file, line, title, fix } of violations) {
      console.log(`::error file=${file},line=${line},title=${title}::${fix}`);
    }
  }
  console.error(
    [
      "These tests guess at how long the indexer takes to ask the source:",
      "",
      ...violations.map(({ file, line, title, fix }) => `${file}:${line}: ${title}. ${fix}`),
    ].join("\n"),
  );
  process.exit(1);
}
