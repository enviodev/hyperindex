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
// A zero delay is a turn of the event loop, not time.
const realDelay = /\bUtils\.delay\((?!0\))([^)]*)\)/;
const realClock = /\b(?:Date\.now|realNow|realSetTimeout)\(/;
// `length - 1` indexes the latest call, which is how a test answers one poll.
const pollSnapshot = /\bgetHeightOrThrowCalls->Array\.length\b(?!\s*-\s*1)/;
const scenarioStart = /\bScenario\.(?:it|run)\(/;

for (const path of resFiles(testRoot)) {
  const file = relative(repoRoot, path);
  const lines = readFileSync(path, "utf8").split("\n");
  // A scenario made with `~virtualTime=true` puts every test run on it on
  // virtual time, unless the test says `~virtualTime=false`.
  const virtualScenarios = new Set<string>();
  // Scenarios a file makes through a function of its own count the same way.
  lines.forEach((line, index) => {
    const bound = line.match(/^let (\w+) =/);
    if (!bound) return;
    const next = lines.findIndex((later, at) => at > index && /^(let|describe)\b/.test(later));
    const region = lines
      .slice(index, next === -1 ? lines.length : next)
      .map((line) => line.replace(/\/\/.*$/, ""));
    if (
      region.some((line) => /\bScenario\.make\(/.test(line)) &&
      region.some((line) => /~virtualTime=true\b/.test(line))
    ) {
      virtualScenarios.add(bound[1]);
    }
  });
  const starts = lines.flatMap((line, index) => (scenarioStart.test(line) ? [index] : []));
  starts.forEach((start, position) => {
    const end = starts[position + 1] ?? lines.length;
    const block = lines.slice(start, end);
    const code = block.map((line) => line.replace(/\/\/.*$/, ""));
    const receiver = block[0].match(/(\w+)\s*->\s*Scenario\.(?:it|run)\(|Scenario\.(?:it|run)\(\s*(\w+)/);
    // `makeScenario(~name=...)->Scenario.it(` spreads the receiver over the
    // lines before the one that names `Scenario.it`.
    const factoryCall = lines
      .slice(Math.max(0, start - 6), start + 1)
      .join("\n")
      .match(/(\w+)\([^()]*\)\s*->\s*Scenario\.(?:it|run)\($/m);
    const name = receiver?.[1] ?? receiver?.[2] ?? factoryCall?.[1];
    const onVirtualScenario =
      name !== undefined &&
      virtualScenarios.has(name) &&
      !code.some((line) => /~virtualTime=false\b/.test(line));
    if (onVirtualScenario || code.some((line) => /~virtualTime=true\b/.test(line))) {
      code.forEach((line, offset) => {
        const delay = line.match(realDelay);
        if (delay) {
          violations.push({
            file,
            line: start + offset + 1,
            title: `Utils.delay(${delay[1]}) on virtual time`,
            fix: `Replace it with \`await indexer.advanceTime(${delay[1]})\`: the source layer's timers only fire when the test advances the clock.`,
          });
        }
        if (realClock.test(line)) {
          violations.push({
            file,
            line: start + offset + 1,
            title: "Reading the real clock on virtual time",
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
    } else {
      // A window shortened on real time races the test's own steps on a loaded
      // runner: what lands between two of them is down to the scheduler.
      const timing = code.findIndex((line) => /~sourceTiming=/.test(line));
      if (timing !== -1) {
        violations.push({
          file,
          line: start + timing + 1,
          title: "~sourceTiming on real time",
          fix: "Add `~virtualTime=true` to the scenario, or to `Scenario.make` for the whole file, and drive its timers with `await indexer.advanceTime(ms)`.",
        });
      }
    }
  });
}

// The source layer's time is whatever its clock says, so a scenario on virtual
// time sees every timer it arms. One armed on the real clock fires on its own
// schedule, between a test's steps, with nothing in the test to say so.
const sourcesRoot = fileURLToPath(new URL("../../envio/src/sources", import.meta.url));
// `Performance.now()` stays: it measures how long real work took, for request
// stats, and a virtual clock would report every request as instant.
const realTime = [
  {
    pattern: /(?<![.\w])(?:setTimeout|clearTimeout|setInterval)\(/,
    use: "`clock.setTimeout(~label, ...)` and `clock.clearTimeout`",
  },
  { pattern: /\bUtils\.delay\(/, use: "`clock->Clock.delay(~label, millis)`" },
  { pattern: /\bDate\.now\(/, use: "`clock.now()`" },
  { pattern: /\bMath\.random\(/, use: "`clock.random()`" },
];
const sourceViolations: violation[] = [];
for (const path of resFiles(sourcesRoot)) {
  const file = relative(repoRoot, path);
  readFileSync(path, "utf8")
    .split("\n")
    .forEach((line, index) => {
      const code = line.replace(/\/\/.*$/, "");
      for (const { pattern, use } of realTime) {
        if (pattern.test(code)) {
          sourceViolations.push({
            file,
            line: index + 1,
            title: `${code.match(pattern)?.[0]}...) on the real clock`,
            fix: `Use ${use} on the clock the module was given: a virtual-time scenario only sees and moves time that goes through it.`,
          });
        }
      }
    });
}

const report = (list: violation[], heading: string) => {
  // An annotation puts the rule on the line that broke it, in the PR diff. The log
  // alone is prose under a step named for the tests, which a reader reaches only
  // after scrolling past the service-container dumps that follow a failed job.
  if (process.env.GITHUB_ACTIONS) {
    for (const { file, line, title, fix } of list) {
      console.log(`::error file=${file},line=${line},title=${title}::${fix}`);
    }
  }
  console.error(
    [heading, "", ...list.map(({ file, line, title, fix }) => `${file}:${line}: ${title}. ${fix}`)].join(
      "\n",
    ),
  );
};

if (violations.length > 0) {
  report(violations, "These tests guess at how long the indexer takes to ask the source:");
}
if (sourceViolations.length > 0) {
  report(sourceViolations, "The source layer reads time the tests can't control:");
}
if (violations.length > 0 || sourceViolations.length > 0) {
  process.exit(1);
}
