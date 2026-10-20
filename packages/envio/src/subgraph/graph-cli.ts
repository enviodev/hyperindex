/**
 * The project's own graph-cli, run inside this process on a worker thread.
 *
 * Its own version, so the generated code is byte-for-byte what the developer
 * gets from `graph codegen`; a worker, so its heap can be sized for it alone —
 * codegen over a large ABI set outgrows Node's default heap long before envio
 * does.
 */

import {
  existsSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  realpathSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { spawn } from "node:child_process";
import { totalmem } from "node:os";
import path from "node:path";
import { Worker } from "node:worker_threads";
import { subgraphBundledCodegen } from "../Core.res.mjs";
import { info, warn } from "../Logging.res.mjs";
import { fetchGraphCli, graphCliVersions } from "./toolchain.ts";

const WORKER = new URL("./graph-cli-worker.mjs", import.meta.url);

/**
 * Three quarters of the machine — the worker is the only thing running — or of
 * the container, whose limit `totalmem` doesn't see.
 */
const HEAP_MB = Math.floor(
  (Math.min(totalmem(), process.constrainedMemory?.() || Infinity) / 2 ** 20) * 0.75,
);

/**
 * Where Node would resolve graph-cli from the project: its own node_modules,
 * then each parent's — a yarn or npm workspace hoists it to the root. A
 * package directory left half-installed (an install that died on a dead git
 * dependency) doesn't count: it can't run.
 */
function graphCliPackage(root: string): string | null {
  for (let dir = path.resolve(root); ; dir = path.dirname(dir)) {
    const candidate = path.join(dir, "node_modules", "@graphprotocol", "graph-cli");
    // pnpm links the package in; its own plugins resolve only from where it lives.
    if (existsSync(path.join(candidate, "package.json"))) {
      const packageDir = realpathSync(candidate);
      if (runnable(packageDir)) return packageDir;
    }
    if (path.dirname(dir) === dir) return null;
  }
}

function runnable(packageDir: string): boolean {
  const bin = legacyBin(packageDir);
  return existsSync(path.join(packageDir, "dist", "commands", "codegen.js")) || (bin !== null && existsSync(bin));
}

/**
 * One place `graph codegen` can come from. The project's own graph-cli is one;
 * a pinned one envio fetches into its own cache is another; a codegen bundled
 * in envio, with no graph-cli at all, slots in here as a third.
 */
export interface CodegenProvider {
  readonly name: string;
  /** Whether using it downloads something: only done when the mappings import generated code. */
  readonly fetches?: boolean;
  /** graph-cli package directories to try, best first; empty when this provider has none. */
  locate(root: string): Promise<string[]>;
}

const projectGraphCli: CodegenProvider = {
  name: "the project's graph-cli",
  locate: async (root) => {
    const found = graphCliPackage(root);
    return found ? [found] : [];
  },
};

const fetchedGraphCli: CodegenProvider = {
  name: "a graph-cli fetched by envio",
  fetches: true,
  locate: async (root) => {
    const found: string[] = [];
    for (const version of graphCliVersions(root)) {
      const packageDir = await fetchGraphCli(version);
      if (packageDir) found.push(packageDir);
    }
    return found;
  },
};

export const codegenProviders: CodegenProvider[] = [projectGraphCli, fetchedGraphCli];

type Outcome = "ok" | "failed" | "outOfMemory";

/**
 * graph-cli before oclif (0.2x) has no `dist/commands/` to run in-process, only
 * its gluegun bin.
 */
function legacyBin(packageDir: string): string | null {
  if (existsSync(path.join(packageDir, "dist", "commands"))) return null;
  try {
    const { bin } = JSON.parse(readFileSync(path.join(packageDir, "package.json"), "utf8"));
    const graph = typeof bin === "string" ? bin : bin?.graph;
    return typeof graph === "string" ? path.join(packageDir, graph) : null;
  } catch {
    return null;
  }
}

function runLegacyGraphCli(bin: string, root: string, command: string, argv: string[]): Promise<Outcome> {
  return new Promise((resolve) => {
    const child = spawn(process.execPath, [`--max-old-space-size=${HEAP_MB}`, bin, command, ...argv], {
      cwd: root,
      stdio: "inherit",
    });
    child.on("error", (error) => {
      console.error(error);
      resolve("failed");
    });
    child.on("exit", (code) => resolve(code === 0 ? "ok" : "failed"));
  });
}

function runGraphCli(packageDir: string, root: string, command: string, argv: string[]): Promise<Outcome> {
  const bin = legacyBin(packageDir);
  if (bin) return runLegacyGraphCli(bin, root, command, argv);
  return new Promise((resolve) => {
    let ok = false;
    const worker = new Worker(WORKER, {
      workerData: { packageDir, command, argv },
      resourceLimits: { maxOldGenerationSizeMb: HEAP_MB },
    });
    worker.on("message", (message: boolean) => (ok = message));
    worker.on("error", (error: NodeJS.ErrnoException) => {
      if (error.code === "ERR_WORKER_OUT_OF_MEMORY") {
        resolve("outOfMemory");
      } else {
        console.error(error);
        resolve("failed");
      }
    });
    worker.on("exit", () => resolve(ok ? "ok" : "failed"));
  });
}

/**
 * Migrations are skipped: they rewrite the developer's `subgraph.yaml` in
 * place, and envio reads a manifest, it doesn't maintain one.
 */
async function runOrThrow(
  graphCli: string,
  root: string,
  manifestFile: string,
  command: string,
  outputDir: string,
  failure: string,
): Promise<void> {
  const outcome = await runGraphCli(graphCli, root, command, [
    path.resolve(root, manifestFile),
    "--output-dir",
    outputDir,
    "--skip-migrations",
  ]);
  if (outcome === "outOfMemory") throw outOfMemory(command);
  if (outcome === "failed") throw new Error(failure);
}

function outOfMemory(command: string): Error {
  return new Error(
    `Envio Subgraph ran \`graph ${command}\` with a ${HEAP_MB} MB heap, three\n` +
      "quarters of this machine's memory, and it ran out. Run it on a machine\n" +
      "with more memory, then start envio again.",
  );
}

/**
 * graph-cli skips migrations here (they rewrite the developer's manifest), and
 * 0.5x then refuses a mapping below apiVersion 0.0.5, which is what an old
 * subgraph says. Codegen reads only the ABIs and the schema, so it is run on a
 * copy beside the manifest with those versions raised.
 */
async function withCodegenManifest<T>(
  manifest: string,
  pathFixes: [string, string][],
  use: (file: string) => Promise<T>,
): Promise<T> {
  let source: string;
  try {
    source = readFileSync(manifest, "utf8");
  } catch {
    return use(manifest);
  }
  let patched = source.replace(/(\bapiVersion:\s*["']?)0\.0\.[0-4]\b/g, "$10.0.5");
  // graph-cli on Linux can't read a file the manifest names in another case
  // than the repo's; the copy names it the repo's way.
  for (const [written, found] of pathFixes) {
    const escaped = written.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    patched = patched.replace(new RegExp(`(\\bfile:\\s*["']?)${escaped}(["']?\\s*$)`, "gm"), `$1${found}$2`);
  }
  if (patched === source) return use(manifest);
  const copy = path.join(path.dirname(manifest), `.envio-codegen-${path.basename(manifest)}`);
  writeFileSync(copy, patched);
  try {
    return await use(copy);
  } finally {
    rmSync(copy, { force: true });
  }
}

/**
 * `graph codegen` from the first provider that has a graph-cli, trying each of
 * its candidates in turn: a fetched graph-cli is a ladder (the project's
 * declared version, then two pins), since no one version reads every manifest.
 * Returns false when no provider has one.
 */
async function runCodegen(
  root: string,
  manifestFile: string,
  outputDir: string,
  needed: boolean,
  flags: string[] = [],
  pathFixes: [string, string][] = [],
): Promise<boolean> {
  for (const provider of codegenProviders) {
    if (provider.fetches && !needed) continue;
    const candidates = await provider.locate(root);
    if (candidates.length === 0) continue;
    for (const [index, graphCli] of candidates.entries()) {
      const outcome = await withCodegenManifest(path.resolve(root, manifestFile), pathFixes, (manifest) =>
        runGraphCli(graphCli, root, "codegen", [manifest, "--output-dir", outputDir, "--skip-migrations", ...flags]),
      );
      if (outcome === "ok") return true;
      if (outcome === "outOfMemory") throw outOfMemory("codegen");
      if (index < candidates.length - 1) {
        info(`Envio Subgraph: \`graph codegen\` failed with ${provider.name} at ${graphCli}; trying the next version.`);
      }
    }
    throw new Error(
      "Envio Subgraph ran `graph codegen` to build the generated code, but it\n" +
        `failed with ${provider.name} (${candidates.length} version${candidates.length === 1 ? "" : "s"} tried) — the error above comes from The Graph's own codegen, so fix it\n` +
        "there and rerun. If `graph codegen` succeeds on its own but fails through\n" +
        "envio, please open an issue: https://github.com/enviodev/hyperindex/issues",
    );
  }
  return false;
}

const RELATIVE_IMPORT = /\bfrom\s*["'](\.\.?\/[^"']+)["']/g;

/**
 * Where the mappings import their generated code from: `graph codegen -o`
 * moves it, and the mappings are the only record of where. Every generated
 * tree has a `schema.ts`, and a template's a `templates.ts`.
 */
/**
 * The project files the manifest's mappings reach through relative imports,
 * breadth first, each with the relative specifiers it imports: an entry file
 * may only re-export handlers written elsewhere (Uniswap v4's do).
 */
function* scanImports(root: string, mappingFiles: string[]): Generator<{ file: string; specifiers: string[] }> {
  const queue = [...new Set(mappingFiles)].map((mappingFile) => path.resolve(root, mappingFile));
  const seen = new Set(queue);
  for (let index = 0; index < queue.length && index < MAX_SCANNED_FILES; index++) {
    const file = queue[index];
    let source: string;
    try {
      source = readFileSync(file, "utf8");
    } catch {
      continue;
    }
    const specifiers = [...source.matchAll(RELATIVE_IMPORT)].map(([, specifier]) => specifier);
    yield { file, specifiers };
    for (const specifier of specifiers) {
      const target = path.resolve(path.dirname(file), specifier);
      for (const candidate of [target, `${target}.ts`, path.join(target, "index.ts")]) {
        if (!seen.has(candidate) && existsSync(candidate) && statSync(candidate).isFile()) {
          seen.add(candidate);
          queue.push(candidate);
          break;
        }
      }
    }
  }
}

export function generatedDir(root: string, mappingFiles: string[]): string {
  for (const { file, specifiers } of scanImports(root, mappingFiles)) {
    for (const specifier of specifiers) {
      const base = path.basename(specifier).replace(/\.ts$/, "");
      if (base === "schema" || base === "templates") {
        return path.resolve(path.dirname(file), path.dirname(specifier));
      }
    }
  }
  return path.join(root, "generated");
}

/**
 * The generated files the mappings import that aren't there. A directory that
 * exists isn't enough: Envio Cloud recreates generated/ empty before the build.
 */
export function missingGeneratedFiles(root: string, mappingFiles: string[], dir: string): string[] {
  const missing = new Set<string>();
  for (const { file, specifiers } of scanImports(root, mappingFiles)) {
    for (const specifier of specifiers) {
      const target = path.resolve(path.dirname(file), specifier);
      if (!target.startsWith(dir + path.sep)) continue;
      const candidates = [target, `${target}.ts`, path.join(target, "index.ts")];
      if (!candidates.some((candidate) => existsSync(candidate) && statSync(candidate).isFile())) {
        missing.add(path.relative(root, target));
      }
    }
  }
  return [...missing];
}

const MAX_SCANNED_FILES = 2_000;

/** Whether any file the mappings reach imports something from `dir`. */
function importsFrom(root: string, mappingFiles: string[], dir: string): boolean {
  for (const { file, specifiers } of scanImports(root, mappingFiles)) {
    for (const specifier of specifiers) {
      if (path.resolve(path.dirname(file), specifier).startsWith(dir + path.sep)) return true;
    }
  }
  return false;
}

export function missingGeneratedCode(root: string, dir: string): Error {
  const relative = path.relative(root, dir);
  return new Error(
    `Envio Subgraph needs the project's generated code, but "${relative}/" is\n` +
      "missing and @graphprotocol/graph-cli isn't installed in the project or any\n" +
      "directory above it. Install the project's dependencies and try again:\n" +
      "  npm install   (or yarn / pnpm install)\n" +
      "Or generate manually:\n" +
      `  pnpm exec graph codegen --output-dir ${relative}`,
  );
}

const GRAPH_CODEGEN = /^(?:(?:npx|pnpm exec|pnpm|yarn|bunx)\s+)?graph\s+codegen\b/;

/**
 * The flags of a `graph codegen` step that change what it writes, which the
 * run envio makes would otherwise drop: `-u` / `--uncrashable` also writes
 * `generated/UncrashableEntityHelpers.ts` (Wildcat's mappings import it), from
 * `--uncrashable-config <file>` or `uncrashable-config.yaml`. Only graph-cli
 * can write it; the bundled codegen has no such helper.
 */
export function codegenFlags(root: string, step: string): string[] {
  const words = step.split(/\s+/);
  const flags: string[] = [];
  for (let index = words.indexOf("codegen") + 1; index > 0 && index < words.length; index++) {
    const word = words[index];
    const [name, inline] = word.split("=", 2);
    if (name === "-u" || name === "--uncrashable") {
      flags.push("--uncrashable");
    } else if (name === "--uncrashable-config" || name === "--uc") {
      const file = inline ?? words[++index];
      if (file) flags.push("--uncrashable-config", path.resolve(root, file.replace(/^["']|["']$/g, "")));
    }
  }
  // graph-cli looks for the default config in its own working directory.
  const fallback = path.join(root, "uncrashable-config.yaml");
  if (flags.length > 0 && !flags.includes("--uncrashable-config") && existsSync(fallback)) {
    flags.push("--uncrashable-config", fallback);
  }
  return flags;
}

/**
 * The project's `codegen` script, step by step, when it runs `graph codegen`
 * itself. Some do more after it — Lido writes `generated/parserData.ts` with a
 * script of its own — and the mappings import what those steps leave.
 */
function codegenSteps(root: string, skip: SkippedSteps = {}): string[] | null {
  let script: unknown;
  try {
    script = JSON.parse(readFileSync(path.join(root, "package.json"), "utf8")).scripts?.codegen;
  } catch {
    return null;
  }
  if (typeof script !== "string") return null;
  const steps = script
    .split("&&")
    .map((step) => step.trim())
    .filter(Boolean)
    .filter((step) => !(skip.renderScripts ?? []).some((script) => runsScript(step, script)))
    .filter((step) => !skip.ranSteps?.includes(step));
  return steps.some((step) => GRAPH_CODEGEN.test(step)) ? steps : null;
}

/**
 * Codegen steps envio already ran to write the manifest, for the network
 * picked: run again, they would write the script's default network over it.
 */
type SkippedSteps = {
  /** The package.json script envio rendered the manifest with itself, and those it runs. */
  renderScripts?: string[];
  /** The codegen script's own steps envio ran before translating. */
  ranSteps?: string[];
};

/** Whether a step runs package.json script `script`: `yarn x`, `npm run x`, `pnpm x`. */
function runsScript(step: string, script: string): boolean {
  const words = step.split(/\s+/);
  const named = words[0] === "npm" || words[1] === "run" ? words[2] : words[1];
  return ["yarn", "npm", "pnpm", "bun"].includes(words[0]) && named === script;
}

/** The project's bins and its workspaces', nearest first, as a package manager puts them on PATH. */
function binDirs(root: string): string[] {
  const dirs: string[] = [];
  for (let dir = path.resolve(root); ; dir = path.dirname(dir)) {
    dirs.push(path.join(dir, "node_modules", ".bin"));
    if (path.dirname(dir) === dir) return dirs;
  }
}

/** A step as the package manager would run it: a shell, with the project's bins on PATH. */
function runScriptStep(root: string, step: string): Promise<void> {
  return new Promise((resolve, reject) => {
    const child = spawn(step, {
      cwd: root,
      shell: true,
      stdio: "inherit",
      env: {
        ...process.env,
        PATH: [...binDirs(root), process.env.PATH].join(path.delimiter),
      },
    });
    child.on("error", reject);
    child.on("exit", (code) =>
      code === 0
        ? resolve()
        : reject(
            new Error(
              `Envio Subgraph ran \`${step}\` from the project's codegen script, and it\n` +
                `exited with ${code} — the error above is the script's own.`,
            ),
          ),
    );
  });
}

/**
 * `ENVIO_SUBGRAPH_CODEGEN`: `bundled` always writes the tree itself, `graph-cli`
 * only ever asks the project's graph-cli, and the default (`auto`) asks
 * graph-cli first and writes the tree itself when graph-cli is missing or fails.
 */
function codegenMode(): "auto" | "bundled" | "graph-cli" {
  const mode = process.env.ENVIO_SUBGRAPH_CODEGEN;
  return mode === "bundled" || mode === "graph-cli" ? mode : "auto";
}

/** envio's own `graph codegen`: needs no install, only the manifest, schema and ABIs. */
export function bundledCodegen(root: string, dir: string, manifestFile: string): string[] {
  const { files } = subgraphBundledCodegen(path.resolve(root, manifestFile), dir);
  info(`Envio Subgraph wrote ${files.length} generated files to "${path.relative(root, dir)}/" without graph-cli.`);
  return files;
}

/**
 * The project's other codegen steps (Lido writes `generated/parserData.ts` with
 * a script of its own), which bundled codegen can't replace. A failure is a
 * warning: the mappings that don't import their output still run.
 */
async function runOtherSteps(root: string, skip: SkippedSteps): Promise<void> {
  for (const step of codegenSteps(root, skip) ?? []) {
    if (GRAPH_CODEGEN.test(step)) continue;
    try {
      await runScriptStep(root, step);
    } catch (error) {
      warn(`${error instanceof Error ? error.message : error}`);
    }
  }
}

/**
 * The generated code is usually gitignored, so it's built when missing. `graph
 * codegen` itself runs in-process, sized and without migrations, wherever the
 * project's codegen script puts it among its steps; when graph-cli is missing
 * or fails, envio writes the tree itself.
 */
export async function ensureGeneratedCode(
  root: string,
  dir: string,
  manifestFile = "subgraph.yaml",
  mappingFiles: string[] = [],
  { pathFixes = [], ...skip }: { pathFixes?: [string, string][] } & SkippedSteps = {},
): Promise<void> {
  const mode = codegenMode();
  if (mode === "bundled") {
    bundledCodegen(root, dir, manifestFile);
    await runOtherSteps(root, skip);
    return;
  }
  const graphCli = graphCliPackage(root);
  const complete = existsSync(dir) && missingGeneratedFiles(root, mappingFiles, dir).length === 0;
  if (complete) {
    if (!graphCli) {
      warn(
        `Envio Subgraph is running the generated code in "${path.relative(root, dir)}/" as it is: ` +
          "@graphprotocol/graph-cli isn't installed, so it can't be rebuilt. If subgraph.yaml, the " +
          "schema or an ABI changed since it was generated, install the project's dependencies.",
      );
    }
    return;
  }
  let bundledFailed = false;
  const needsGraphCli = (codegenSteps(root, skip) ?? []).some((step) => codegenFlags(root, step).length > 0);
  if (!graphCli && mode === "auto" && !needsGraphCli) {
    // Nothing to build when no mapping imports a generated file.
    if (missingGeneratedFiles(root, mappingFiles, dir).length === 0) return;
    info("Envio Subgraph found no @graphprotocol/graph-cli in the project; writing the generated code itself.");
    try {
      bundledCodegen(root, dir, manifestFile);
      await runOtherSteps(root, skip);
      return;
    } catch (error) {
      bundledFailed = true;
      warn(
        `Envio Subgraph couldn't write the generated code itself: ${error instanceof Error ? error.message : error}. ` +
          "Trying a graph-cli fetched with npm.",
      );
    }
  }

  try {
    for (const step of codegenSteps(root, skip) ?? ["graph codegen"]) {
      if (!GRAPH_CODEGEN.test(step)) {
        try {
          await runScriptStep(root, step);
        } catch (error) {
          // A step that needs the project's own tools (truffle, a mustache
          // render) can't run when its install never worked; `graph codegen`
          // still can, so the failure is reported rather than fatal.
          if (binDirs(root).some((dir) => existsSync(dir))) throw error;
          warn(
            `Envio Subgraph skipped the codegen script step \`${step}\`: the project's dependencies aren't installed, so ` +
              "its tools are missing. Running graph codegen without it.",
          );
        }
        continue;
      }
      // With no graph-cli anywhere, the mapping that imports the missing code
      // reports it, naming that mapping.
      const needed = importsFrom(root, mappingFiles, dir);
      if (!(await runCodegen(root, manifestFile, dir, needed, codegenFlags(root, step), pathFixes))) return;
    }
  } catch (error) {
    if (mode === "graph-cli" || bundledFailed) throw error;
    warn(
      "Envio Subgraph: the project's `graph codegen` failed (see above); writing the generated code " +
        "itself. Set ENVIO_SUBGRAPH_CODEGEN=graph-cli to stop at the failure instead.",
    );
    bundledCodegen(root, dir, manifestFile);
    await runOtherSteps(root, skip);
  }
}

/**
 * `graph build` compiles the mappings with `asc` against the real
 * `@graphprotocol/graph-ts`. That is the type check a subgraph project already
 * has, and running it in `envio dev` keeps the feedback loop the developer
 * knows — a type error reads the same here as it does on Graph Node.
 *
 * Only in dev, and only when something it reads has changed: it is an
 * AssemblyScript compile, not something to pay on every restart.
 */
export async function typeCheckMappings(root: string, manifestFile = "subgraph.yaml"): Promise<void> {
  const graphCli = graphCliPackage(root);
  if (!graphCli) return;

  const inputs = [manifestFile, "schema.graphql", "src", "abis"]
    .map((entry) => path.join(root, entry))
    .filter((entry) => existsSync(entry))
    .map((entry) => fingerprint(entry))
    .join("|");

  const stamp = path.join(root, ".envio", "graph-build.stamp");
  if (existsSync(stamp) && readFileSync(stamp, "utf8") === inputs) return;

  await runOrThrow(
    graphCli,
    root,
    manifestFile,
    "build",
    path.resolve(root, "build"),
    "Envio Subgraph ran `graph build` to type-check the mappings, and it\n" +
      "failed — the error above comes from The Graph's own AssemblyScript\n" +
      "compiler, so fix it there and rerun.",
  );

  mkdirSync(path.dirname(stamp), { recursive: true });
  writeFileSync(stamp, inputs);
}

function fingerprint(entry: string): string {
  const stats = statSync(entry);
  if (!stats.isDirectory()) {
    return `${entry}:${stats.mtimeMs}:${stats.size}`;
  }
  return readdirSync(entry)
    .sort()
    .map((child) => fingerprint(path.join(entry, child)))
    .join(",");
}
