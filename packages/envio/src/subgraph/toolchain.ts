/**
 * The pieces of a subgraph's toolchain envio fetches itself when the project's
 * own `node_modules` can't supply them.
 *
 * graph-node never installs a repo's npm dependencies at index time, it runs
 * compiled WASM. A team moving a subgraph expects one command to work in the
 * repo as it is, and a repo whose full install fails (a dead git dependency in
 * an old graph-cli lockfile, a vanished gluegun fork, ETARGET) would otherwise
 * stop before the first line of a mapping ran. Only two things are needed:
 *
 *  - the packages the mappings actually import (`@openzeppelin/subgraphs`,
 *    `@protofire/subgraph-toolkit`, ...), found by walking the mapping import
 *    graph, at the versions the repo's lockfile or package.json names;
 *  - a graph-cli, to run `graph codegen`, at a version that installs.
 *
 * Both are installed with npm into a cache directory of envio's own, away from
 * the repo, with no lifecycle scripts, skipping git, file and workspace
 * dependencies and every devDependency the mappings don't import.
 */

import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { cpSync, existsSync, mkdirSync, readFileSync, readdirSync, renameSync, rmSync, statSync, writeFileSync } from "node:fs";
import { builtinModules } from "node:module";
import { homedir } from "node:os";
import path from "node:path";
import { info, warn } from "./log.ts";

/** Where fetched packages live: `ENVIO_SUBGRAPH_CACHE_DIR`, else the user's cache. */
export function cacheDir(): string {
  return (
    process.env.ENVIO_SUBGRAPH_CACHE_DIR ||
    path.join(process.env.XDG_CACHE_HOME || path.join(homedir(), ".cache"), "envio", "subgraph")
  );
}

/**
 * npm into `dir` (a prefix with its own node_modules), atomically: installed
 * beside it, then renamed, so an interrupted install never leaves a half
 * cache that looks complete.
 */
async function npmInstallInto(dir: string, specs: string[]): Promise<void> {
  if (existsSync(path.join(dir, ".envio-installed"))) return;
  const staging = `${dir}.tmp-${process.pid}`;
  rmSync(staging, { recursive: true, force: true });
  mkdirSync(staging, { recursive: true });
  writeFileSync(path.join(staging, "package.json"), JSON.stringify({ name: "envio-subgraph-cache", private: true }));
  const output: string[] = [];
  await new Promise<void>((resolve, reject) => {
    const child = spawn(
      "npm",
      [
        "install",
        "--no-audit",
        "--no-fund",
        "--no-package-lock",
        "--ignore-scripts",
        "--legacy-peer-deps",
        "--loglevel=error",
        ...specs,
      ],
      { cwd: staging, env: process.env },
    );
    child.stdout.on("data", (chunk) => output.push(String(chunk)));
    child.stderr.on("data", (chunk) => output.push(String(chunk)));
    child.on("error", reject);
    child.on("exit", (code) =>
      code === 0 ? resolve() : reject(new Error(`npm install ${specs.join(" ")} exited with ${code}\n${output.join("").slice(-1500)}`)),
    );
  }).catch((error) => {
    rmSync(staging, { recursive: true, force: true });
    throw error;
  });
  writeFileSync(path.join(staging, ".envio-installed"), specs.join("\n"));
  rmSync(dir, { recursive: true, force: true });
  mkdirSync(path.dirname(dir), { recursive: true });
  renameSync(staging, dir);
}

// --- what the repo declares -------------------------------------------------

const EXACT_VERSION = /^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/;

/** A package.json spec npm can fetch from the registry: a version or range, not a git, file, link or workspace one. */
function registrySpec(spec: unknown): string | null {
  if (typeof spec !== "string" || spec === "" || spec === "*" || spec === "latest") return null;
  if (/^(?:git|github|file|link|workspace|portal|patch|http|https|npm:|[^@\s]+\/[^@\s]+$)/.test(spec) || spec.includes("://")) {
    return null;
  }
  return spec;
}

function readJson(file: string): any {
  try {
    return JSON.parse(readFileSync(file, "utf8"));
  } catch {
    return null;
  }
}

function escapeRegExp(text: string): string {
  return text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

/** The version a lockfile in `dir` resolved `name` to: npm, yarn (1 and berry) or pnpm. */
function lockedVersion(dir: string, name: string): string | null {
  const npmLock = readJson(path.join(dir, "package-lock.json"));
  if (npmLock) {
    const version = npmLock.packages?.[`node_modules/${name}`]?.version ?? npmLock.dependencies?.[name]?.version;
    if (EXACT_VERSION.test(version ?? "")) return version;
  }
  const read = (file: string) => (existsSync(file) ? readFileSync(file, "utf8") : null);
  const yarn = read(path.join(dir, "yarn.lock"));
  if (yarn) {
    for (const block of yarn.split(/\n\s*\n/)) {
      const header = block.split("\n").find((line) => line !== "" && !line.startsWith("#"));
      if (!header) continue;
      const entries = header.replace(/:\s*$/, "").split(/,\s*/).map((entry) => entry.trim().replace(/^"|"$/g, ""));
      if (!entries.some((entry) => entry.startsWith(`${name}@`))) continue;
      const version = block.match(/^\s+version:?\s+"?([^"\s]+)"?/m)?.[1];
      if (version && EXACT_VERSION.test(version)) return version;
    }
  }
  const pnpm = read(path.join(dir, "pnpm-lock.yaml"));
  if (pnpm) {
    const version = pnpm.match(new RegExp(`^\\s+'?/?${escapeRegExp(name)}@(\\d[^:(')\\s]*)`, "m"))?.[1];
    if (version && EXACT_VERSION.test(version)) return version;
  }
  return null;
}

/**
 * The version of `name` to fetch: the lockfile's, else package.json's range,
 * from the project's directory up through the workspace root; null for latest.
 */
export function declaredVersion(root: string, name: string): string | null {
  const directories: string[] = [];
  for (let dir = path.resolve(root); ; dir = path.dirname(dir)) {
    directories.push(dir);
    if (path.dirname(dir) === dir) break;
  }
  for (const dir of directories) {
    const locked = lockedVersion(dir, name);
    if (locked) return locked;
  }
  for (const dir of directories) {
    const manifest = readJson(path.join(dir, "package.json"));
    const spec = registrySpec(
      manifest?.dependencies?.[name] ??
        manifest?.devDependencies?.[name] ??
        manifest?.peerDependencies?.[name] ??
        manifest?.optionalDependencies?.[name],
    );
    if (spec) return spec;
  }
  return null;
}

// --- the packages the mappings import -----------------------------------------

const BARE_IMPORT = /(?:\bfrom\s*|\bimport\s*\(?\s*|\brequire\s*\(\s*)["']([@\w][^"'\s]*)["']/g;
/** A name npm would accept: lowercase, optionally scoped. */
const NPM_NAME = /^(?:@[a-z0-9~-][a-z0-9._~-]*\/)?[a-z0-9~-][a-z0-9._~-]*$/;
const RELATIVE_IMPORT = /(?:\bfrom\s*|\bimport\s*\(?\s*|\brequire\s*\(\s*)["'](\.\.?\/[^"']*)["']/g;
const BUILTINS = new Set(builtinModules);
/** Never fetched: the shim replaces them. */
const SHIMMED = new Set(["@graphprotocol/graph-ts", "matchstick-as"]);
const MAX_SCANNED_FILES = 2_000;

function packageName(specifier: string): string | null {
  if (specifier.startsWith("node:") || specifier.startsWith("#")) return null;
  const parts = specifier.split("/");
  const name = specifier.startsWith("@") ? parts.slice(0, 2).join("/") : parts[0];
  if (!name || !NPM_NAME.test(name) || BUILTINS.has(name) || SHIMMED.has(name)) return null;
  return name;
}

/** Whether Node would find `name` from `fromDir`: a node_modules there or in any parent. */
function resolvableFrom(fromDir: string, name: string): boolean {
  for (let dir = path.resolve(fromDir); ; dir = path.dirname(dir)) {
    if (existsSync(path.join(dir, "node_modules", name, "package.json"))) return true;
    if (path.dirname(dir) === dir) return false;
  }
}

/**
 * The npm packages the mappings import that the project can't resolve, found by
 * walking the mapping files' relative imports. `generated/` is not walked: it
 * imports only graph-ts.
 */
export function missingMappingPackages(root: string, mappingFiles: string[]): string[] {
  const queue = [...new Set(mappingFiles)].map((file) => path.resolve(root, file));
  const seen = new Set(queue);
  const missing = new Set<string>();
  for (let index = 0; index < queue.length && index < MAX_SCANNED_FILES; index++) {
    const file = queue[index];
    let source: string;
    try {
      source = readFileSync(file, "utf8");
    } catch {
      continue;
    }
    for (const [, specifier] of source.matchAll(BARE_IMPORT)) {
      const name = packageName(specifier);
      if (name && !resolvableFrom(path.dirname(file), name)) missing.add(name);
    }
    for (const [, specifier] of source.matchAll(RELATIVE_IMPORT)) {
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
  return [...missing].sort();
}

/**
 * Fetches `names` into the cache, each at the version the project declares,
 * falling back to the latest when that version is gone (ETARGET). Returns the
 * `node_modules` directory holding them, or null when nothing installed. A
 * package that can't be fetched at all (a workspace package that isn't on the
 * registry) is left out, so the mapping that imports it reports it by name.
 */
export async function fetchMappingPackages(root: string, names: string[]): Promise<string | null> {
  if (names.length === 0) return null;
  const specs = names.map((name) => {
    const version = declaredVersion(root, name);
    return version ? `${name}@${version}` : name;
  });
  const key = createHash("sha1").update(specs.join("\n")).digest("hex").slice(0, 12);
  const dir = path.join(cacheDir(), "packages", key);
  const modules = path.join(dir, "node_modules");
  if (existsSync(path.join(dir, ".envio-installed"))) return modules;

  info(`Envio Subgraph is fetching ${specs.join(", ")} into ${dir}: the project's own node_modules lacks ${names.length === 1 ? "it" : "them"}.`);
  try {
    await npmInstallInto(dir, specs);
    return modules;
  } catch {
    // One bad spec fails the whole install; find which.
  }
  const installed: string[] = [];
  for (const [index, spec] of specs.entries()) {
    const one = path.join(cacheDir(), "packages", createHash("sha1").update(spec).digest("hex").slice(0, 12));
    for (const attempt of spec === names[index] ? [spec] : [spec, names[index]]) {
      try {
        await npmInstallInto(one, [attempt]);
        installed.push(one);
        break;
      } catch (error) {
        if (attempt === names[index]) {
          warn(`Envio Subgraph could not fetch ${names[index]} (${String(error).split("\n")[0]}); a mapping importing it will fail by name.`);
        }
      }
    }
  }
  if (installed.length === 0) return null;
  // Merge the per-package installs into one node_modules, so resolution has a single place to look.
  const merged = path.join(dir, "node_modules");
  mkdirSync(merged, { recursive: true });
  for (const one of installed) {
    for (const entry of readdirSync(path.join(one, "node_modules"))) {
      cpSync(path.join(one, "node_modules", entry), path.join(merged, entry), { recursive: true, force: false });
    }
  }
  writeFileSync(path.join(dir, ".envio-installed"), specs.join("\n"));
  return modules;
}

// --- graph-cli ----------------------------------------------------------------

/**
 * The newest graph-cli whose own dependencies still install, and the one the
 * generated code of older subgraphs is closest to: 0.51 has none of the
 * dead git pins that 0.45 and older do (hugomrdias/concat-stream, the
 * edgeandnode/gluegun fork) and still accepts a schema graph-cli 0.9x rejects
 * (`@entity` without `immutable`, nullable list members are the next gate).
 */
export const OLDEST_INSTALLABLE_GRAPH_CLI = "0.51.0";
/** For manifests newer than 0.51 reads (specVersion 1.x, indexerHints). */
export const NEWEST_GRAPH_CLI = "0.98.1";

/** The first x.y.z in a spec, as numbers. */
function leadingVersion(spec: string): [number, number, number] | null {
  const match = spec.match(/(\d+)\.(\d+)\.(\d+)/);
  return match ? [Number(match[1]), Number(match[2]), Number(match[3])] : null;
}

function atLeast(version: [number, number, number], minimum: [number, number, number]): boolean {
  for (let index = 0; index < 3; index++) {
    if (version[index] !== minimum[index]) return version[index] > minimum[index];
  }
  return true;
}

/**
 * graph-cli versions to try, best first: the project's own when it is new
 * enough to install (a version the repo's author ran), then the two pins.
 */
export function graphCliVersions(root: string): string[] {
  const versions: string[] = [];
  const declared = declaredVersion(root, "@graphprotocol/graph-cli");
  const parsed = declared ? leadingVersion(declared) : null;
  if (declared && parsed && atLeast(parsed, [0, 50, 0])) versions.push(declared);
  versions.push(OLDEST_INSTALLABLE_GRAPH_CLI, NEWEST_GRAPH_CLI);
  return [...new Set(versions)];
}

/** The package directory of `@graphprotocol/graph-cli@version` in the cache, fetching it first if need be. */
export async function fetchGraphCli(version: string): Promise<string | null> {
  const dir = path.join(cacheDir(), "graph-cli", version.replace(/[^0-9A-Za-z.^~<>=-]/g, "_"));
  const packageDir = path.join(dir, "node_modules", "@graphprotocol", "graph-cli");
  if (!existsSync(path.join(dir, ".envio-installed"))) {
    info(`Envio Subgraph is fetching @graphprotocol/graph-cli@${version} into ${dir} to generate code: the project's own isn't usable.`);
    try {
      await npmInstallInto(dir, [`@graphprotocol/graph-cli@${version}`]);
    } catch (error) {
      warn(`Envio Subgraph could not fetch @graphprotocol/graph-cli@${version}: ${String(error).split("\n").slice(0, 3).join(" ")}`);
      return null;
    }
  }
  return existsSync(path.join(packageDir, "package.json")) ? packageDir : null;
}
