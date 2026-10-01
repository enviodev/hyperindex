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

function graphCliPackage(root: string): string | null {
  const dir = path.resolve(root, "node_modules", "@graphprotocol", "graph-cli");
  // pnpm links the package in; its own plugins resolve only from where it lives.
  return existsSync(dir) ? realpathSync(dir) : null;
}

type Outcome = "ok" | "failed" | "outOfMemory";

function runGraphCli(packageDir: string, command: string, argv: string[]): Promise<Outcome> {
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
  const outcome = await runGraphCli(graphCli, command, [
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
  for (const mappingFile of new Set(mappingFiles)) {
    const file = path.resolve(root, mappingFile);
    let source: string;
    try {
      source = readFileSync(file, "utf8");
    } catch {
      continue;
    }
    for (const [, specifier] of source.matchAll(RELATIVE_IMPORT)) {
      const base = path.basename(specifier).replace(/\.ts$/, "");
      if (base === "schema" || base === "templates") {
        return path.resolve(path.dirname(file), path.dirname(specifier));
      }
    }
  }
  return path.join(root, "generated");
}

export function missingGeneratedCode(root: string, dir: string): Error {
  const relative = path.relative(root, dir);
  return new Error(
    `Envio Subgraph needs the project's generated code, but "${relative}/" is\n` +
      "missing and @graphprotocol/graph-cli isn't installed.\n" +
      "Install dependencies and try again:\n" +
      "  pnpm install\n" +
      "Or generate manually:\n" +
      `  pnpm exec graph codegen --output-dir ${relative}`,
  );
}

/** The generated code is usually gitignored, so it's built when missing. */
export async function ensureGeneratedCode(root: string, dir: string): Promise<void> {
  if (existsSync(dir)) return;
  const graphCli = graphCliPackage(root);
  // Reported when a mapping fails to import it, naming that mapping.
  if (!graphCli) return;

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
