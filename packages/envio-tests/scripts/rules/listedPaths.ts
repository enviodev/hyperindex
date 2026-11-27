// A rule that covers or spares a file by its path stops doing so the day the
// file is renamed, and nothing says so: the list still reads as if it worked.

import { performanceAllowed } from "./performanceReads.ts";
import type { file, violation } from "./shared.ts";
import { runtimeRoot } from "./shared.ts";
import { clockedModules } from "./sourceClock.ts";
import { loggingAllowed } from "./testLogging.ts";

export const listedPaths = [
  ...clockedModules.map((path) => ({ path, listedIn: "sourceClock.ts" })),
  ...Object.keys(performanceAllowed).map((module) => ({
    path: `${runtimeRoot}${module}`,
    listedIn: "performanceReads.ts",
  })),
  ...Object.keys(loggingAllowed).map((path) => ({ path, listedIn: "testLogging.ts" })),
];

export const findListedPathsThatMoved = (files: file[]): violation[] => {
  const paths = new Set(files.map(({ path }) => path));
  return listedPaths
    .filter(({ path }) => !paths.has(path))
    .map(({ path, listedIn }) => ({
      file: `packages/envio-tests/scripts/rules/${listedIn}`,
      line: 1,
      title: `\`${path}\` is listed here and is not in the repo`,
      fix: "Rename the entry along with the file, or drop it if the file is gone.",
    }));
};
