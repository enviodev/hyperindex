// A scenario on virtual time only moves when it advances its clock, so real
// time spent between steps changes nothing it can observe, and a count taken
// before a step stands in for what `expectNewHeightCalls` checks exactly.
// A zero delay is a turn of the event loop, not time.

import type { file, violation } from "./shared.ts";
import { isRealTimeAt, testRescriptFiles, withoutLineComment } from "./shared.ts";

const realDelay = /\bUtils\.delay\((?!0\))([^)]*)\)/;
const realClock = /\bDate\.now\(/;
// `length - 1` indexes the latest call, which is how a test answers one poll.
const pollSnapshot = /\bgetHeightOrThrowCalls->Array\.length\b(?!\s*-\s*1)/;
const scenarioStart = /\bScenario\.(?:it|run)\(/;

// Scenarios run on virtual time unless `~virtualTime=false` takes them off it,
// on `Scenario.make` for every test of that scenario or on one test. Scenarios
// a file makes through a function of its own count the same way.
const realTimeScenariosOf = (lines: string[]) => {
  const realTimeScenarios = new Set<string>();
  lines.forEach((line, index) => {
    const bound = line.match(/^let (\w+) =/);
    if (!bound) return;
    // The binding ends at the first line back at the margin: the call's own
    // closing paren, or whatever top-level code follows a one-line call.
    const next = lines.findIndex((later, at) => at > index && /^\S/.test(later));
    const end = next === -1 ? lines.length : /^\)/.test(lines[next]) ? next + 1 : next;
    const region = lines.slice(index, end).map((line) => line.replace(/\/\/.*$/, ""));
    if (
      region.some((line) => /\bScenario\.make\(/.test(line)) &&
      region.some((line) => /~virtualTime=false\b/.test(line))
    ) {
      realTimeScenarios.add(bound[1]);
    }
  });
  return realTimeScenarios;
};

export const findRealTimeOnVirtualTime = (files: file[]): violation[] =>
  testRescriptFiles(files).flatMap(({ path, text }) => {
    const found: violation[] = [];
    const lines = text.split("\n");
    const isHelper = path.includes("/helpers/");
    const realTimeScenarios = realTimeScenariosOf(lines);
    lines.forEach((line, index) => {
      const code = withoutLineComment(line);
      // Helpers declare the default, and a test of a real-time scenario turns
      // virtual time back on with it.
      if (/~virtualTime=true\b/.test(code) && realTimeScenarios.size === 0 && !isHelper) {
        found.push({
          file: path,
          line: index + 1,
          title: "~virtualTime=true is the default",
          fix: "Delete it: scenarios run on virtual time unless they opt out.",
        });
      }
      // Real time is the exception, and the reason is what keeps it from
      // spreading by copy and paste.
      const previous = lines[index - 1] ?? "";
      if (
        !isHelper &&
        /~virtualTime=false\b/.test(code) &&
        !/~virtualTime=false\b.*(?<!:)\/\//.test(line) &&
        !/^\s*\/\//.test(previous)
      ) {
        found.push({
          file: path,
          line: index + 1,
          title: "~virtualTime=false without a reason",
          fix: "Say on the line above why this test needs real time, such as a source talking to a real server.",
        });
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
      const onRealTime =
        (name !== undefined &&
          realTimeScenarios.has(name) &&
          !code.some((line) => /~virtualTime=true\b/.test(line))) ||
        code.some((line) => /~virtualTime=false\b/.test(line));
      if (!onRealTime) {
        code.forEach((line, offset) => {
          const delay = line.match(realDelay);
          if (delay && !isRealTimeAt(lines, start + offset)) {
            found.push({
              file: path,
              line: start + offset + 1,
              title: `Utils.delay(${delay[1]}) on virtual time`,
              fix: `Replace it with \`await indexer.advanceTime(${delay[1]})\`: the source layer's timers only fire when the test advances the clock.`,
            });
          }
          if (realClock.test(line) && !isRealTimeAt(lines, start + offset)) {
            found.push({
              file: path,
              line: start + offset + 1,
              title: "Reading the real clock on virtual time",
              fix: "Time the scenario by how far it advanced: real time says nothing about when a virtual timer fired.",
            });
          }
          if (pollSnapshot.test(line)) {
            found.push({
              file: path,
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
          found.push({
            file: path,
            line: start + timing + 1,
            title: "~sourceTiming on real time",
            fix: "Drop `~virtualTime=false` and drive its timers with `await indexer.advanceTime(ms)`.",
          });
        }
      }
    });
    return found;
  });
