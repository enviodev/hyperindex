import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { defineConfig } from "vitest/config";

const packageRoot = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(packageRoot, "../..");
const devAddon = path.join(repoRoot, "target", "debug", "envio.node");

const testFile = /(_test\.res\.mjs|\.test\.ts)$/;
const testFiles = (fs.readdirSync(path.join(packageRoot, "test"), { recursive: true }) as string[])
  .map((file) => path.join("test", file))
  .filter((file) => testFile.test(file) && !file.startsWith(path.join("test", "helpers")));

// A fresh process per file costs one to three seconds of imports, more than
// most files spend testing, so files share a worker and its module cache.
// `FreshProcess` puts the runtime's process-global state back to a fresh
// process's before each file. A file that leaves other
// state behind is marked `// vitest: isolate` and gets a process of its own.
// The source is what's read, so a new file is classified with no list to keep.
const needsOwnProcess = (file: string) => {
  const source = file.endsWith(".res.mjs") ? file.replace(/\.mjs$/, "") : file;
  const text = fs.readFileSync(path.join(packageRoot, fs.existsSync(source) ? source : file), "utf8");
  return /vitest: isolate/.test(text);
};
const isolated = testFiles.filter(needsOwnProcess);

const shared = {
  // Files run in parallel: every scenario indexer gets a Postgres schema of
  // its own (see IndexerRunner.run). Tests within a file stay sequential —
  // the handler registration a scenario activates is process-global.
  sequence: {
    concurrent: false,
  },
  pool: "forks" as const,
  testTimeout: 30_000,
  hookTimeout: 30_000,
  env: {
    ENVIO_DEV_ADDON: devAddon,
  },
  passWithNoTests: true,
  setupFiles: ["test/helpers/FreshProcess.res.mjs"],
  server: {
    deps: {
      // Externalize non-test files so they load via native Node.js ESM,
      // preventing dual module cache between vite and native import()
      external: [/^(?!.*\.test\.)(?!.*_test\.)(?!.*\/test\/).*$/i],
    },
  },
};

export default defineConfig({
  test: {
    // Once for the whole run, outside the projects: it clears directories and
    // sweeps schemas that running files would otherwise lose.
    globalSetup: ["test/helpers/globalSetup.ts", "test/helpers/GlobalSetup.res.mjs"],
    passWithNoTests: true,
    projects: [
      {
        test: {
          ...shared,
          name: "isolated",
          include: isolated,
          isolate: true,
        },
      },
      {
        test: {
          ...shared,
          name: "shared",
          include: ["test/**/*_test.res.mjs", "test/**/*.test.ts"],
          exclude: ["test/helpers/**", ...isolated],
          isolate: false,
        },
      },
    ],
  },
});
