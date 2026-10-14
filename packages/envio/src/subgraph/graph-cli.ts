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
  statSync,
  writeFileSync,
} from "node:fs";
import { spawn } from "node:child_process";
import { totalmem } from "node:os";
import path from "node:path";
import { Worker } from "node:worker_threads";

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
 * then each parent's — a yarn or npm workspace hoists it to the root.
 */
function graphCliPackage(root: string): string | null {
  for (let dir = path.resolve(root); ; dir = path.dirname(dir)) {
    const candidate = path.join(dir, "node_modules", "@graphprotocol", "graph-cli");
    // pnpm links the package in; its own plugins resolve only from where it lives.
    if (existsSync(path.join(candidate, "package.json"))) return realpathSync(candidate);
    if (path.dirname(dir) === dir) return null;
  }
}

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
  command: string,
  outputDir: string,
  failure: string,
): Promise<void> {
  const outcome = await runGraphCli(graphCli, root, command, [
    path.resolve(root, "subgraph.yaml"),
    "--output-dir",
    outputDir,
    "--skip-migrations",
  ]);
  if (outcome === "outOfMemory") {
    throw new Error(
      `Envio Subgraph ran \`graph ${command}\` with a ${HEAP_MB} MB heap, three\n` +
        "quarters of this machine's memory, and it ran out. Run it on a machine\n" +
        "with more memory, then start envio again.",
    );
  }
  if (outcome === "failed") throw new Error(failure);
}

const RELATIVE_IMPORT = /\bfrom\s*["'](\.\.?\/[^"']+)["']/g;

/**
 * Where the mappings import their generated code from: `graph codegen -o`
 * moves it, and the mappings are the only record of where. Every generated
 * tree has a `schema.ts`, and a template's a `templates.ts`.
 */
export function generatedDir(root: string, mappingFiles: string[]): string {
  // Breadth first from the manifest's files: an entry file may only re-export
  // handlers written elsewhere (Uniswap v4's do), and those import the code.
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
    const next: string[] = [];
    for (const [, specifier] of source.matchAll(RELATIVE_IMPORT)) {
      const base = path.basename(specifier).replace(/\.ts$/, "");
      if (base === "schema" || base === "templates") {
        return path.resolve(path.dirname(file), path.dirname(specifier));
      }
      const target = path.resolve(path.dirname(file), specifier);
      for (const candidate of [target, `${target}.ts`, path.join(target, "index.ts")]) {
        if (!seen.has(candidate) && existsSync(candidate) && statSync(candidate).isFile()) {
          seen.add(candidate);
          next.push(candidate);
          break;
        }
      }
    }
    queue.push(...next);
  }
  return path.join(root, "generated");
}

const MAX_SCANNED_FILES = 2_000;

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
 * The project's `codegen` script, step by step, when it runs `graph codegen`
 * itself. Some do more after it — Lido writes `generated/parserData.ts` with a
 * script of its own — and the mappings import what those steps leave.
 */
function codegenSteps(root: string): string[] | null {
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
    .filter(Boolean);
  return steps.some((step) => GRAPH_CODEGEN.test(step)) ? steps : null;
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
 * The generated code is usually gitignored, so it's built when missing. `graph
 * codegen` itself runs in-process, sized and without migrations, wherever the
 * project's codegen script puts it among its steps.
 */
export async function ensureGeneratedCode(root: string, dir: string): Promise<void> {
  if (existsSync(dir)) return;
  const graphCli = graphCliPackage(root);
  // Reported when a mapping fails to import it, naming that mapping.
  if (!graphCli) return;

  for (const step of codegenSteps(root) ?? ["graph codegen"]) {
    if (!GRAPH_CODEGEN.test(step)) {
      await runScriptStep(root, step);
      continue;
    }
    await runOrThrow(
      graphCli,
      root,
      "codegen",
      dir,
      "Envio Subgraph ran `graph codegen` to build the generated code, but it\n" +
        "failed — the error above comes from The Graph's own codegen, so fix it\n" +
        "there and rerun. If `graph codegen` succeeds on its own but fails through\n" +
        "envio, please open an issue: https://github.com/enviodev/hyperindex/issues",
    );
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
export async function typeCheckMappings(root: string): Promise<void> {
  const graphCli = graphCliPackage(root);
  if (!graphCli) return;

  const inputs = ["subgraph.yaml", "schema.graphql", "src", "abis"]
    .map((entry) => path.join(root, entry))
    .filter((entry) => existsSync(entry))
    .map((entry) => fingerprint(entry))
    .join("|");

  const stamp = path.join(root, ".envio", "graph-build.stamp");
  if (existsSync(stamp) && readFileSync(stamp, "utf8") === inputs) return;

  await runOrThrow(
    graphCli,
    root,
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
