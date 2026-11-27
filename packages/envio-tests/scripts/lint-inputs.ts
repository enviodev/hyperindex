// Each rule lives in `rules/`, takes the repo's files and returns what breaks
// it; `lint.test.ts` holds a bad and a good input for every one. A rule's
// reason is its `fix` message, which is all a reader of a failed run sees.

import { execFileSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { findMissingDocPaths } from "./rules/docReferences.ts";
import { findFakedTimers } from "./rules/fakeTimers.ts";
import { findUnnamedHeightWaits } from "./rules/heightCalls.ts";
import { findUnannotatedMagic } from "./rules/magicAnnotation.ts";
import { findLogicInMigratedDirectories } from "./rules/migratedToRust.ts";
import { findGuessedWaits } from "./rules/mockSteps.ts";
import { findPerformanceReads } from "./rules/performanceReads.ts";
import { findRawFieldPaths } from "./rules/rawFieldPath.ts";
import { findUnsetDurations } from "./rules/reportedDurations.ts";
import { summarizeRescriptDirection } from "./rules/rescriptDirection.ts";
import type { file, violation } from "./rules/shared.ts";
import { runtimeRoot } from "./rules/shared.ts";
import { findRealClockInSources } from "./rules/sourceClock.ts";
import { findLoggingInTests } from "./rules/testLogging.ts";
import { findRealTimeOnVirtualTime } from "./rules/virtualTime.ts";

const repoRoot = fileURLToPath(new URL("../../../", import.meta.url));

const git = (...args: string[]) =>
  execFileSync("git", args, { cwd: repoRoot, encoding: "utf8", maxBuffer: 64 * 1024 * 1024 });

// Untracked files count: a test written a minute ago is linted before it is
// ever staged. Ignored ones (build output, `node_modules`) don't.
const files: file[] = git("ls-files", "--cached", "--others", "--exclude-standard", "-z")
  .split("\0")
  .filter((path) => path !== "" && existsSync(join(repoRoot, path)))
  .map((path) => {
    let text: string | undefined;
    return {
      path,
      get text() {
        text ??= readFileSync(join(repoRoot, path), "utf8");
        return text;
      },
    };
  });

const groups: { heading: string; rules: ((files: file[]) => violation[])[] }[] = [
  {
    heading: "These tests guess at how long the indexer takes to ask the source:",
    rules: [findGuessedWaits, findRealTimeOnVirtualTime, findUnnamedHeightWaits, findFakedTimers, findUnsetDurations],
  },
  {
    heading: "The runtime reads time the tests can't control:",
    rules: [findRealClockInSources, findPerformanceReads],
  },
  {
    heading: "This ReScript compiles, and the repo still refuses it:",
    rules: [findUnannotatedMagic, findRawFieldPaths, findLoggingInTests, (files) => findLogicInMigratedDirectories(files)],
  },
  {
    heading: "The contributor docs name what isn't in the repo:",
    rules: [findMissingDocPaths],
  },
];

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

// CI checks out one commit, so there is no merge base there and the count is
// printed only where there is history to count against.
const printRescriptDirection = () => {
  let base: string;
  let changedPaths: string[];
  try {
    base = git("merge-base", "HEAD", "origin/main").trim();
    changedPaths = [
      ...git("diff", "--name-only", "-z", base, "--", runtimeRoot).split("\0"),
      ...git("ls-files", "--others", "--exclude-standard", "-z", "--", runtimeRoot).split("\0"),
    ].filter((path) => path !== "");
  } catch {
    return;
  }
  const atBase = changedPaths.flatMap((path) => {
    try {
      return [{ path, text: git("show", `${base}:${path}`) }];
    } catch {
      return [];
    }
  });
  const { net, changed } = summarizeRescriptDirection(
    atBase,
    files.filter(({ path }) => changedPaths.includes(path)),
  );
  const signed = (count: number) => (count > 0 ? `+${count}` : `${count}`);
  console.log(
    [
      `ReScript runtime against main: ${signed(net)} non-blank lines in ${runtimeRoot}**/*.res (new runtime logic goes in Rust).`,
      ...changed.map(({ path, net }) => `  ${signed(net)} ${path}`),
    ].join("\n"),
  );
};

let failed = false;
for (const { heading, rules } of groups) {
  const violations = rules.flatMap((rule) => rule(files));
  if (violations.length > 0) {
    if (failed) console.error("");
    report(violations, heading);
    failed = true;
  }
}

printRescriptDirection();

if (failed) {
  process.exit(1);
}
