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

const delay = /^\s*(?:await\s+)?Utils\.delay\(0\)\s*$/;
const resolveCall =
  /^\s*(?:await\s+)?\S*\b(resolveGetItemsOrThrow|resolveGetHeightOrThrow|drainItemsQueries)\b/;

const resFiles = (dir: string): string[] =>
  readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const path = join(dir, entry.name);
    if (entry.isDirectory()) return resFiles(path);
    return entry.isFile() && entry.name.endsWith(".res") ? [path] : [];
  });

const violations: string[] = [];
for (const path of resFiles(testRoot)) {
  const lines = readFileSync(path, "utf8").split("\n");
  lines.forEach((line, index) => {
    if (!delay.test(line)) return;
    let next = index + 1;
    while (next < lines.length && (lines[next].trim() === "" || lines[next].trim().startsWith("//"))) next++;
    const match = next < lines.length ? lines[next].match(resolveCall) : null;
    if (match) violations.push(`${relative(process.cwd(), path)}:${index + 1}: before ${match[1]}`);
  });
}

if (violations.length > 0) {
  console.error(
    [
      "Utils.delay(0) waits for a mock call that the resolve below can answer in advance:",
      "",
      ...violations,
      "",
      "Delete the delay. With nothing pending the resolve holds its answer for the next",
      "matching call; Scenario.run fails the test if no call ever claims it.",
    ].join("\n"),
  );
  process.exit(1);
}
