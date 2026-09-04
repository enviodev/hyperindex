// `await Utils.delay(0)` in front of a mock resolve is a guess at how many await
// hops the indexer needs before it asks the source. The guess is unwritable
// without trial and error and breaks the day production code gains an await.
// It is also unnecessary: a resolve with no matching call pending holds its
// answer for the next matching call, so the test can answer a question before
// it has been asked.

import { readdirSync, readFileSync } from "node:fs";
import { join, relative } from "node:path";
import { fileURLToPath } from "node:url";

const testRoot = fileURLToPath(new URL("../test", import.meta.url));
// Paths are reported against the repo root rather than the cwd, so they mean the
// same thing whether this runs from the package, from the root, or from CI — and
// so GitHub can attach an annotation to the line.
const repoRoot = fileURLToPath(new URL("../../../", import.meta.url));

const delay = /^\s*(?:await\s+)?Utils\.delay\(0\)\s*$/;
const resolveCall =
  /^\s*(?:await\s+)?\S*\b(resolveGetItemsOrThrow|resolveGetHeightOrThrow|drainItemsQueries)\b/;

// The scan has to reach the resolver past whatever sits between it and the
// delay. A comment that hid a violation would make the lint quietly useless.
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

const violations: { file: string; line: number; resolver: string }[] = [];
for (const path of resFiles(testRoot)) {
  const lines = readFileSync(path, "utf8").split("\n");
  lines.forEach((line, index) => {
    if (!delay.test(line)) return;
    const match = nextCodeLine(lines, index + 1)?.match(resolveCall) ?? null;
    if (match) {
      violations.push({ file: relative(repoRoot, path), line: index + 1, resolver: match[1] });
    }
  });
}

if (violations.length > 0) {
  // An annotation puts the rule on the line that broke it, in the PR diff. The log
  // alone is prose under a step named for the tests, which a reader reaches only
  // after scrolling past the service-container dumps that follow a failed job.
  if (process.env.GITHUB_ACTIONS) {
    for (const { file, line, resolver } of violations) {
      console.log(
        `::error file=${file},line=${line},title=Utils.delay(0) before a mock resolve::` +
          `Delete this Utils.delay(0). The ${resolver} below holds its answer for the next ` +
          `matching call, so it can answer before the call arrives.`,
      );
    }
  }
  console.error(
    [
      "Utils.delay(0) waits for a mock call that the resolve below can answer in advance:",
      "",
      ...violations.map(({ file, line, resolver }) => `${file}:${line}: before ${resolver}`),
      "",
      "Delete the delay. With nothing pending the resolve holds its answer for the next",
      "matching call; Scenario.run fails the test if no call ever claims it.",
    ].join("\n"),
  );
  process.exit(1);
}
