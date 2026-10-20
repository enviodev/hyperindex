/**
 * Turns a translated manifest into envio registrations.
 *
 * Each manifest handler becomes an `onEvent` / `onBlock` / `contractRegister`
 * wrapper that runs the mapping synchronously inside `runSync`: reads try the
 * in-memory state first, a miss schedules the async op and suspends, and the
 * replay loop reruns the mapping once what it asked for has landed.
 */

import { instancesAt, rememberInstance } from "./template-instances.ts";
import { existsSync, readFileSync } from "node:fs";
import { registerHooks } from "node:module";
import { fileURLToPath, pathToFileURL } from "node:url";
import path from "node:path";
import { indexer } from "../Api.res.mjs";
import { Db, Hasura, serverPort } from "../Env.res.mjs";
import { info, warn } from "../Logging.res.mjs";
import { subgraphCreatingHandlers, subgraphFileToJavascript } from "../Core.res.mjs";
import { install as installCallSource } from "../sources/CallSource.res.mjs";
import { fetchCalls, resetCallBackends } from "./calls-source.ts";
import {
  currentScope,
  runInScope,
  runInScopeUntilSettled,
  type FileCreate,
  type RegisterPass,
  type Scope,
  type SubgraphSchema,
} from "./scope.ts";
import {
  contextOf,
  Address,
  assemblyScriptPrimitives,
  BigInt as GraphBigInt,
  Bytes,
  changetype,
  retagChangetype,
  retagEach,
  installCallHook,
  installLegacySignatureHook,
  installHosts,
  installHandlerCreateHook,
  setLegacyNullOperands,
  installRegisterHook,
  installRegisterMissHook,
  installFileTemplates,
  fileCreateId,
  decodeBase64,
  ethereum,
  type EventInput,
  type EventKind,
  json as jsonNamespace,
  makeBlockHandlerBlock,
  makeEvent as makeGraphEvent,
  makeCall as makeGraphCall,
  makeCallBlock,
  callInputDecodes,
  type CallKind,
  commitRegisterWrites,
  resetRegisterStore,
  POSITION_BLOCK,
  ROUND_SPAN,
  ethereumValueToJs,
} from "./graph-ts.ts";
import { encodeArg, decodeArg, makeCallEffect } from "./calls.ts";
import { functionSignature } from "./abi-types.ts";
import { resetRpcClients } from "./rpc.ts";
import {
  EVENT_CLASSES_EXPORT,
  OPERATORS_HELPER,
  RETAG_EACH_HELPER,
  RETAG_HELPER,
  operators,
} from "./assemblyscript.ts";
import { makeHostEffects, normalizeIpfsPath } from "./hosts.ts";
import { createHash } from "node:crypto";
import { advanceRollup } from "./rollup.ts";
import { graftBaseNotice } from "./graft.ts";
import { fetchMappingPackages, missingMappingPackages } from "./toolchain.ts";
import { ensureGeneratedCode, generatedDir, missingGeneratedCode, typeCheckMappings } from "./graph-cli.ts";
import { unknown, unsupported } from "./errors.ts";
import { runSyncCounted } from "./stats.ts";
import { resolveAssemblyScriptPackage } from "./as-package.ts";
import { registerSlots } from "./register-slots.ts";

const SHIM_URL = new URL("./graph-ts.ts", import.meta.url).href;
const REGEX_SHIM_URL = new URL("./assemblyscript-regex.ts", import.meta.url).href;
const ENVIO_PACKAGE_URL = new URL("../../", import.meta.url).href;

const jsonFromString = (line: string) => (jsonNamespace as any).fromString(line);

/**
 * Skips the preload pass, so every read a mapping makes misses and the handler
 * replays as often as it possibly can. The replay-stress suite runs the whole
 * subgraph suite this way: a mapping must produce the same store whether its
 * reads were preloaded or not.
 */
const skipPreload = process.env.ENVIO_SUBGRAPH_SKIP_PRELOAD === "1";

/** Escape hatch from the create analysis: every handler gets a register pass. */
const registerEveryHandler = process.env.ENVIO_SUBGRAPH_REGISTER_ALL_HANDLERS === "1";

type EventHandler = {
  event: string;
  name: string;
  handler: string;
  receipt: boolean;
  inputs?: EventInput[];
  /** `topic1`–`topic3`, keyed by position among the indexed parameters. */
  topics?: Record<string, string[]>;
};
type CallHandler = {
  function: string;
  handler: string;
  /** The call trigger the translator minted for it. */
  name: string;
  inputs?: { name: string; type: string }[];
  outputs?: { name: string; type: string }[];
};
/** As the translator serialises its `BlockFilter`. */
type BlockHandler = {
  handler: string;
  filter: { every: number } | "once" | "call";
  /** The call trigger a `filter: call` handler runs on. */
  callEvent?: string;
};
type DataSource = {
  kind: string;
  name: string;
  network?: string;
  chainId?: number;
  address?: string;
  startBlock?: number;
  endBlock?: number;
  mappingFile: string;
  apiVersion?: string;
  /** ABI name to file, relative to `root`. */
  abis?: Record<string, string>;
  entities?: string[];
  eventHandlers: EventHandler[];
  callHandlers?: CallHandler[];
  blockHandlers: BlockHandler[];
  context?: Record<string, { type: string; data: string }>;
  isTemplate: boolean;
};
type SubgraphConfig = {
  specVersion: string;
  dataSources: DataSource[];
  templates: DataSource[];
  declaresEthCalls: boolean;
  /** Set when the manifest has a `graft:` block; the indexer ignores it. */
  graft?: { base: string; block: number };
  graftNotice?: string;
  timeseriesEntities?: string[];
  aggregations?: SubgraphSchema["aggregations"];
  /** The config's contract name for each data source and template. */
  contractAccessors: Record<string, string>;
  root: string;
  /** The manifest's name within `root`: `--config` may name another than subgraph.yaml. */
  manifestFile?: string;
  rpcUrls: string[];
  /** Per chain id, the reorg depth a block handler's header reads are held back by. */
  blockHeaderLag?: Record<number, number>;
  isDev: boolean;
} & SubgraphSchema;

const AS_DATE = Symbol.for("envio.subgraph.date");

/**
 * Where a call sits in its chain for the register pass's store: after every log
 * of its block, then by transaction and position in the transaction. graph-node
 * orders a call by its transaction among the logs (after that transaction's own
 * events); the handler pass follows that order exactly, so this only steers
 * what a register pass may read — a create decided on state written by a log of
 * a later transaction of the same block reads it one transaction early.
 */
function callPosition(event: any): number {
  const transaction = Math.min(Number(event.transaction?.transactionIndex ?? 0), 499);
  return event.block.number * POSITION_BLOCK + 500_000 + transaction * 1000 + Math.min(event.logIndex, 999);
}

/**
 * A mapping may import AssemblyScript from outside the manifest's directory:
 * graph codegen writes `generated/` beside the package.json while the manifest,
 * schema and mappings sit in `src/` (StakeWise). Any TypeScript that is neither
 * a dependency nor envio's own is the project's.
 */
function isOutsideSource(url: string): boolean {
  return (
    url.startsWith("file:") &&
    url.endsWith(".ts") &&
    !url.endsWith(".d.ts") &&
    !url.includes("/node_modules/") &&
    !url.startsWith(ENVIO_PACKAGE_URL)
  );
}

let hooksInstalled = false;
/**
 * Some mapping is below apiVersion 0.0.5, where graph-node reads through a null
 * pointer instead of trapping. Files are compiled once for the whole project,
 * so one old mapping makes every file tolerant.
 */
let legacyNulls = false;
let projectRoot: string | null = null;
/**
 * `node_modules` envio fetched for packages the mappings import and the
 * project can't resolve (its own install failed or never ran). A parent URL
 * inside it is where those specifiers are resolved from, and so are the
 * packages' own dependencies.
 */
let fetchedModulesParent: string | null = null;
/** Every project file the load hook has compiled, so their exports can be read back. */
const projectModules = new Set<string>();

/**
 * Mappings resolve `@graphprotocol/graph-ts` to the shim. The project's own
 * files — its mappings and `generated/` — are AssemblyScript, and load through
 * the addon, which turns each into the JavaScript that computes what `asc`
 * would (`subgraph/assemblyscript.rs`).
 */
function installResolveHook(root: string) {
  projectRoot = pathToFileURL(path.resolve(root) + path.sep).href;
  if (hooksInstalled) return;
  hooksInstalled = true;
  // The addon's output carries an inline source map back to the mapping, so a
  // stack trace names the line the developer wrote.
  process.setSourceMapsEnabled(true);

  registerHooks({
    resolve(specifier: string, context: any, nextResolve: any) {
      if (
        specifier === "@graphprotocol/graph-ts" ||
        specifier.startsWith("@graphprotocol/graph-ts/") ||
        // Matchstick re-exports graph-ts' `log`, and some mappings import it
        // from there; its test helpers have no meaning outside a test.
        specifier === "matchstick-as" ||
        specifier.startsWith("matchstick-as/")
      ) {
        return { url: SHIM_URL, shortCircuit: true };
      }
      // A library of AssemblyScript's own memory-level matching, which the
      // JavaScript transform of a mapping library can't run.
      if (specifier === "assemblyscript-regex") return { url: REGEX_SHIM_URL, shortCircuit: true };
      let resolved;
      try {
        resolved = nextResolve(specifier, context);
      } catch (error: any) {
        const bare = !specifier.startsWith(".") && !specifier.startsWith("/") && !specifier.includes(":");
        let fetched;
        if (fetchedModulesParent && bare && error?.code === "ERR_MODULE_NOT_FOUND") {
          try {
            fetched = nextResolve(specifier, { ...context, parentURL: fetchedModulesParent });
          } catch {}
        }
        if (fetched) {
          resolved = fetched;
        } else {
          // A library written in AssemblyScript has no JavaScript entry for Node
          // to find (as-base64's package.json names no `main`); asc reads its
          // assembly/index.ts.
          const asFile =
            resolveAssemblyScriptPackage(specifier, context?.parentURL) ??
            resolveAssemblyScriptPackage(specifier, fetchedModulesParent ?? undefined);
          if (!asFile) throw error;
          return { url: asFile, shortCircuit: true };
        }
      }
      // A subgraph project's package.json has no `type`, so its mappings and
      // its `generated/` would load as CommonJS and reach the shim — a real ES
      // module — through `require()`, which Node refuses inside a cycle. They
      // are ES modules; saying so is what lets them import it.
      if (projectRoot && resolved?.url && (resolved.url.startsWith(projectRoot) || isOutsideSource(resolved.url))) {
        return { ...resolved, format: "module" };
      }
      return resolved;
    },
    // Taken over before any other loader sees the file: a TypeScript
    // transpiler would refuse AssemblyScript it has no reason to accept, and
    // would strip `changetype`'s type argument before it could be read.
    load(url: string, context: any, nextLoad: any) {
      const isProjectFile =
        projectRoot !== null && (url.startsWith(projectRoot) || isOutsideSource(url)) && !url.includes("/node_modules/");
      // A mapping library is AssemblyScript too — OpenZeppelin's
      // @amxx/graphprotocol-utils, @protofire/subgraph-toolkit — and Node
      // won't even strip types under node_modules. envio's own sources are
      // TypeScript, not AssemblyScript, and stay out of it.
      const isMappingLibrary =
        url.includes("/node_modules/") && !url.endsWith(".d.ts") && !url.startsWith(ENVIO_PACKAGE_URL);
      if (!projectRoot || !url.endsWith(".ts") || !(isProjectFile || isMappingLibrary)) {
        return nextLoad(url, context);
      }
      const file = fileURLToPath(url);
      projectModules.add(url);
      return {
        format: "module",
        source: subgraphFileToJavascript(readFileSync(file, "utf8"), file, legacyNulls),
        shortCircuit: true,
      };
    },
  });

  // AssemblyScript builtins the generated code uses as globals.
  const globals = globalThis as any;
  globals.changetype ??= changetype;
  globals[OPERATORS_HELPER] ??= operators;
  globals[RETAG_HELPER] ??= retagChangetype;
  globals[RETAG_EACH_HELPER] ??= retagEach;
  globals.assert ??= (value: unknown, message?: string) => {
    if (!value) throw new Error(message ?? "assertion failed");
    return value;
  };
  for (const [name, namespace] of Object.entries(assemblyScriptPrimitives)) {
    globals[name] ??= namespace;
  }

  // AssemblyScript's Date takes and sets its time as an i64, which the shim
  // holds as a bigint; JavaScript's refuses one.
  if (!(globals.Date as any)[AS_DATE]) {
    const JsDate: DateConstructor = globals.Date;
    const toNumber = (value: unknown) => (typeof value === "bigint" ? Number(value) : value);
    class AsDate extends JsDate {
      constructor(...args: unknown[]) {
        super(...(args.map(toNumber) as []));
      }
      setTime(time: number | bigint): number {
        return super.setTime(Number(time));
      }
      static fromString(text: string): Date {
        return new AsDate(JsDate.parse(text));
      }
    }
    Object.defineProperty(AsDate, AS_DATE, { value: true });
    globals.Date = AsDate;
  }

  // AssemblyScript's typed arrays are made over an existing buffer with
  // `Uint8Array.wrap(buffer)`; JavaScript has the constructor for it.
  for (const Array of [Int8Array, Uint8Array, Int16Array, Uint16Array, Int32Array, Uint32Array, Float32Array, Float64Array]) {
    (Array as any).wrap ??= (buffer: ArrayBuffer, byteOffset?: number, length?: number) =>
      new Array(buffer, byteOffset, length);
  }

  // AssemblyScript's DataView reads and writes a 64-bit integer as `u64`/`i64`
  // under these names; JavaScript's only as a bigint, under `*Big*` ones.
  const view = DataView.prototype as any;
  view.getUint64 ??= function (this: DataView, offset: number, littleEndian?: boolean) {
    return this.getBigUint64(offset, littleEndian);
  };
  view.getInt64 ??= function (this: DataView, offset: number, littleEndian?: boolean) {
    return this.getBigInt64(offset, littleEndian);
  };
  view.setUint64 ??= function (this: DataView, offset: number, value: bigint | number, littleEndian?: boolean) {
    this.setBigUint64(offset, BigInt.asUintN(64, BigInt(value)), littleEndian);
  };
  view.setInt64 ??= function (this: DataView, offset: number, value: bigint | number, littleEndian?: boolean) {
    this.setBigInt64(offset, BigInt.asIntN(64, BigInt(value)), littleEndian);
  };
}

/**
 * `topicN` narrows the Nth indexed parameter to the logs whose topic is one of
 * the listed words; as a `where`, it narrows to that parameter's decoded
 * values. The translator has refused a parameter hashed into its topic.
 */
function topicFilter(handler: EventHandler): { params: Record<string, unknown[]> } | undefined {
  const topics = Object.entries(handler.topics ?? {});
  if (topics.length === 0) return undefined;
  const indexed = (handler.inputs ?? []).filter((input) => input.indexed);
  const params: Record<string, unknown[]> = {};
  for (const [position, words] of topics) {
    const input = indexed[Number(position) - 1];
    params[input.key] = words.map((word) => fromTopic(input.type, word));
  }
  return { params };
}

function fromTopic(type: string, topic: string): unknown {
  const word = topic.toLowerCase().replace(/^0x/, "").padStart(64, "0");
  if (type === "address") return `0x${word.slice(24)}`;
  if (type === "bool") return BigInt(`0x${word}`) !== 0n;
  // A fixed-size byte string is left-aligned in its word.
  if (type.startsWith("bytes")) return `0x${word.slice(0, Number(type.slice(5)) * 2)}`;
  const bits = Number(type.replace(/^u?int/, "") || 256);
  const value = BigInt(`0x${word}`);
  return type.startsWith("uint") ? BigInt.asUintN(bits, value) : BigInt.asIntN(bits, value);
}

async function loadMapping(
  root: string,
  generated: string,
  mappingFile: string,
  scope: Scope,
): Promise<Record<string, any>> {
  const url = pathToFileURL(path.resolve(root, mappingFile)).href;
  try {
    // graph-node instantiates the module once per data source, with a host
    // context already in place, so a mapping may read `dataSource.network()`
    // at module top level — Balancer's constants do. The import runs inside a
    // scope carrying that data source for the same reason.
    return await runInScopeUntilSettled(scope, () => import(url));
  } catch (exn) {
    const message = exn instanceof Error ? exn.message : String(exn);
    // Only reachable when codegen couldn't run up front, so this reports why
    // rather than retrying: Node caches a failed resolution for the process.
    if (message.includes(generated) && !existsSync(generated)) {
      throw missingGeneratedCode(root, generated);
    }
    // An unknown named import fails at Node's ESM link step, before any Proxy
    // in the shim can see it — rewrap it with the mapping that caused it.
    throw new Error(`Envio Subgraph failed to load the mapping ${mappingFile}.\n  ${message}`);
  }
}

/**
 * The generated event class each handler declares, keyed by the handler
 * function itself. A manifest's mapping file may re-export handlers written in
 * other files (SSV's does), and the class is exported only by the module the
 * handler is written in.
 */
const eventClasses = new Map<Function, Function>();
const indexedModules = new Set<string>();

async function indexEventClasses(): Promise<void> {
  for (const url of projectModules) {
    if (indexedModules.has(url)) continue;
    indexedModules.add(url);
    let module: Record<string, any>;
    try {
      // Already evaluated: this only reads its namespace back.
      module = await import(url);
    } catch {
      continue;
    }
    const classes = module[EVENT_CLASSES_EXPORT];
    if (!classes) continue;
    for (const [name, Class] of Object.entries(classes)) {
      const handler = module[name];
      if (typeof handler === "function" && typeof Class === "function") eventClasses.set(handler, Class);
    }
  }
}

type Effect = {
  name: string;
  handler: (args: { input: unknown; context: unknown; cacheKey: string; checkpointId: bigint }) => Promise<unknown>;
};

const REGISTER_SUSPEND = Symbol("envio.subgraph.register.suspend");

/** envio's `Suspend` (a ReScript exception) and the register pass's own: control flow, not errors. */
function isBridgeSignal(error: unknown): boolean {
  return error === REGISTER_SUSPEND || (typeof error === "object" && error !== null && "RE_EXN_ID" in error);
}

/**
 * Results the register pass has already fetched, across events and blocks.
 *
 * A host op's input carries the block it is evaluated at, so an entry can never
 * go stale — and a factory calling `symbol()` on the same token for every pair
 * it creates asks the same question hundreds of times. envio's own effect cache
 * is out of reach here: it hangs off the processing context, and this runs at
 * fetch time.
 */
const registerCache = new Map<string, { value?: unknown; error?: unknown }>();
const REGISTER_CACHE_LIMIT = 20_000;
/**
 * The register passes of a response's items run concurrently, so the same op
 * at the same block — every pair a factory creates in one block reading the
 * factory — is usually still in flight when the next pass asks for it.
 */
const registerInFlight = new Map<string, Promise<unknown>>();

/**
 * What the finished register passes cost in host ops (contract calls, balances,
 * block lookups) each. `ChainFetching` reads it to decide how many register
 * passes one fetched response may hold: a pass that makes no call needs no
 * limit, a pass that makes a dozen is what keeps a response from committing.
 * Unknown (undefined) until enough passes have finished to say.
 */
const registerCost = { hostOps: 0, passes: 0 };
const REGISTER_COST_MIN_PASSES = 20;
(globalThis as any).__envioSubgraphRegisterCostPerItem = () =>
  registerCost.passes < REGISTER_COST_MIN_PASSES ? undefined : registerCost.hostOps / registerCost.passes;

async function runRegisterHost(effect: Effect, input: unknown, chainId: number): Promise<unknown> {
  return effect.handler({
    input,
    // Only `blockTimestamp` reads the context, and only for the chain id, which
    // the input already carries for every other host op.
    context: { chain: { id: chainId } },
    cacheKey: "",
    checkpointId: 0n,
  });
}

/**
 * The register pass's half of the sync bridge (§5).
 *
 * `contractRegister` runs at fetch time with a context that can only register
 * addresses — no in-memory store, so no effects. But a factory mapping routinely
 * reads a contract *before* deciding what to create, so the answer has to arrive
 * somehow: the op is started, the mapping is suspended, and the round is
 * replayed once it lands. Same shape as the handler pass, with the results
 * memoised here instead of in envio's effect tables.
 */
/**
 * A host op that failed, not a mapping that threw. The two are told apart
 * because the register pass forgives a mapping error — see `runRegisterRounds`
 * — and forgiving this one would silently drop the `dataSource.create()` calls
 * the pass exists to collect.
 */
class RegisterHostFailure extends Error {
  constructor(op: string, readonly reason: unknown) {
    super(`Envio Subgraph could not resolve ${op} while registering contracts: ${String(reason)}`);
    this.cause = reason;
  }
}

function registerHostSync(scope: Scope, effect: Effect, input: unknown) {
  const key = `${effect.name}\u0000${typeof input === "string" ? input : JSON.stringify(input)}`;
  const resolved = scope.resolved ?? new Map();
  scope.resolved = resolved;

  const hit = resolved.get(key) ?? registerCache.get(key);
  if (hit) {
    if ("error" in hit) throw new RegisterHostFailure(effect.name, hit.error);
    return hit.value;
  }

  const awaiting = scope.awaiting ?? [];
  scope.awaiting = awaiting;
  let flight = registerInFlight.get(key);
  if (!flight) {
    registerCost.hostOps++;
    const started = runRegisterHost(effect, input, scope.dataSource.chainId);
    flight = started;
    registerInFlight.set(key, started);
    const settle = () => {
      if (registerInFlight.get(key) === started) registerInFlight.delete(key);
    };
    started.then(settle, settle);
  }
  awaiting.push(
    flight.then(
      (value) => {
        resolved.set(key, { value });
        if (registerCache.size >= REGISTER_CACHE_LIMIT) registerCache.clear();
        registerCache.set(key, { value });
      },
      // A failure is remembered for this event only: a transport error that
      // fails the batch must not poison every later block too.
      (error) => resolved.set(key, { error }),
    ),
  );
  throw REGISTER_SUSPEND;
}

/**
 * A batch's register passes run concurrently, and a pass's writes reach the
 * register store only when it completes. Every Comptroller event in Venus's
 * first batch missed the Market an earlier event was still creating, and
 * repeated its ~20 creation calls at its own block. So a pass that misses an
 * entity an earlier pass of its chain also missed, and is still running,
 * waits for the earliest such pass once and reads again — the per-key order
 * graph-node's sequential processing gives. Independent events stay
 * concurrent; a key nobody ends up writing costs one wait.
 *
 * An earlier pass that hasn't read the key yet — Dolomite's admin handler
 * saves each Token after a contract call — isn't among its missers, so a miss
 * while any earlier pass of the chain still runs is only provisional: once the
 * pass ends, it waits for those passes and runs again before its writes count.
 */
const missers = new Map<string, RegisterPass[]>();

/** Each chain's running passes and the passes waiting on them, by position. */
type ChainPasses = {
  running: RegisterPass[];
  waiters: { position: number; release: () => void }[];
};
const chainPasses = new Map<number, ChainPasses>();

if (process.env.ENVIO_SUBGRAPH_LOG_MEMORY) {
  const t = setInterval(() => {
    let running = 0;
    for (const p of chainPasses.values()) running += p.running.length;
    const m = process.memoryUsage();
    // eslint-disable-next-line no-console
    console.log(`[mem] heap=${Math.round(m.heapUsed / 1e6)}MB ext=${Math.round(m.external / 1e6)}MB ab=${Math.round(m.arrayBuffers / 1e6)}MB passes=${running} inflight=${registerInFlight.size} cache=${registerCache.size} missers=${missers.size} slots=${JSON.stringify(registerSlots.stats())}`);
  }, 5000);
  t.unref();
}

/** Passes start in about the order of their events, so this mostly appends. */
function insertByPosition<T extends { position: number }>(list: T[], item: T) {
  let at = list.length;
  while (at > 0 && list[at - 1].position > item.position) at--;
  list.splice(at, 0, item);
}

function startRegisterPass(chainId: number, position: number): { pass: RegisterPass; settle: () => void } {
  let resolve!: () => void;
  const pass: RegisterPass = {
    chainId,
    position,
    done: new Promise<void>((done) => (resolve = done)),
    settled: false,
    missed: [],
    provisional: false,
  };
  const passes = chainPasses.get(chainId) ?? { running: [], waiters: [] };
  chainPasses.set(chainId, passes);
  insertByPosition(passes.running, pass);
  const settle = () => {
    pass.settled = true;
    passes.running.splice(passes.running.indexOf(pass), 1);
    const first = passes.running[0]?.position ?? Infinity;
    while (passes.waiters.length > 0 && passes.waiters[0].position <= first) passes.waiters.shift()!.release();
    if (passes.running.length === 0 && passes.waiters.length === 0) chainPasses.delete(chainId);
    for (const key of pass.missed) {
      const remaining = (missers.get(key) ?? []).filter((other) => other !== pass);
      if (remaining.length === 0) missers.delete(key);
      else missers.set(key, remaining);
    }
    registerCost.passes++;
    resolve();
  };
  return { pass, settle };
}

function earlierPassRunning(pass: RegisterPass): boolean {
  const first = chainPasses.get(pass.chainId)?.running[0];
  return first !== undefined && first.position < pass.position;
}

function earlierPassesSettled(pass: RegisterPass): Promise<void> {
  const passes = chainPasses.get(pass.chainId);
  if (!passes || !earlierPassRunning(pass)) return Promise.resolve();
  return new Promise((release) => insertByPosition(passes.waiters, { position: pass.position, release }));
}

function onRegisterMiss(scope: Scope, key: string) {
  const pass = scope.pass;
  if (!pass) return;
  const list = missers.get(key) ?? [];
  if (!scope.waitedKeys?.has(key)) {
    const earlier = list.find((other) => other.position < pass.position && !other.settled);
    if (earlier) {
      (scope.waitedKeys ??= new Set()).add(key);
      (scope.awaiting ??= []).push(earlier.done);
      scope.waitsOnPass = true;
      throw REGISTER_SUSPEND;
    }
  }
  if (!list.includes(pass)) {
    list.push(pass);
    list.sort((a, b) => a.position - b.position);
    missers.set(key, list);
    pass.missed.push(key);
  }
  if (!pass.provisional && earlierPassRunning(pass)) pass.provisional = true;
}

/**
 * True when the pass's round must run again: a read missed while an earlier
 * pass was running, which may have written it since. Its writes are dropped;
 * a create it made stands, and the rerun registers nothing twice.
 */
async function rerunProvisional(scope: Scope): Promise<boolean> {
  const pass = scope.pass;
  if (!pass?.provisional) return false;
  pass.provisional = false;
  scope.writes = undefined;
  const settled = earlierPassesSettled(pass);
  await (scope.slot ? scope.slot.pause(settled) : settled);
  return true;
}

const maxRegisterRounds = 100;

async function runRegisterRounds(scope: Scope, fn: () => void): Promise<void> {
  for (let round = 1; round <= maxRegisterRounds; round++) {
    scope.awaiting = undefined;
    // A suspended round is replayed from the top, so its writes are dropped.
    scope.writes = undefined;
    let suspended = false;
    try {
      runInScope(scope, fn);
    } catch (error) {
      if (error !== REGISTER_SUSPEND) {
        // A host op that failed is never forgiven: the mapping was about to
        // decide what to create from its answer, and the handler pass cannot
        // repair a missed registration — addresses are registered at fetch
        // time. `untilAnswered` has already outlasted anything transient.
        if (error instanceof RegisterHostFailure) throw error;
        // This pass exists to collect `dataSource.create()` calls, and it runs
        // against a store that only holds what earlier register passes wrote —
        // so a handler that assumes its entities exist can throw here even
        // though it is perfectly correct, before or after a create. What it
        // registered until then stands; the same mapping runs again with the
        // real store, and any error that is genuinely the mapping's surfaces
        // there.
        if (await rerunProvisional(scope)) continue;
        commitRegisterWrites(scope);
        return;
      }
      suspended = true;
    }
    const awaiting = scope.awaiting;
    if (!suspended) {
      if (await rerunProvisional(scope)) continue;
      commitRegisterWrites(scope);
      return;
    }
    if (!awaiting || awaiting.length === 0) {
      throw new Error(
        "Envio Subgraph suspended the register pass with nothing to wait for. " +
          "Please open an issue: https://github.com/enviodev/hyperindex/issues",
      );
    }
    const everything = Promise.all(awaiting);
    const pausing = scope.waitsOnPass === true;
    scope.waitsOnPass = false;
    await (pausing && scope.slot ? scope.slot.pause(everything) : everything);
  }
  throw new Error(
    `Envio Subgraph replayed a mapping's dataSource.create() pass ${maxRegisterRounds} times ` +
      "without it settling. This usually means the mapping isn't deterministic across reruns.",
  );
}

/**
 * A subgraph team's first move is to POST a query to the indexer's port, the
 * way graph-node serves one — which answers /metrics only.
 */
function announceWhereToQuery() {
  info(
    `Envio Subgraph writes the subgraph's entities to Postgres (database "${Db.database}", ` +
      `schema "${Db.publicSchema}"). This process serves no GraphQL: port ${serverPort} answers ` +
      "/metrics and /healthz only. " +
      (Hasura.enabled
        ? `Hasura (${Hasura.url}) serves envio's own GraphQL over those tables, not The Graph's query API. `
        : "") +
      "The Graph's query API (/subgraphs/name/<name>) is served from the same database by " +
      "envio-serve's subgraph API.",
  );
}

/**
 * The template addresses register passes registered, by chain. A handler pass
 * runs soon after its event's register pass, so the latest ones are enough.
 */
const registeredTemplates = new Set<string>();
/** Templates with a block handler: their instances' creation blocks are kept. */
const blockTemplates = new Set<string>();
const REGISTERED_TEMPLATES_LIMIT = 100_000;
const unregisteredCreates = new Set<string>();

/**
 * The block and round each registered address was created in, by the same key.
 * graph-node runs a data source's events of its creation block in a later round
 * than the handler that created it, so a register pass for them must read what
 * that handler's pass saved, whatever the log order. A round past the position
 * span is clamped.
 */
const registrationRounds = new Map<string, { block: number; round: number }>();

function roundOf(chainId: number, name: string, address: string, block: number): number {
  const entry = registrationRounds.get(`${chainId}:${name}:${address.toLowerCase()}`);
  return entry !== undefined && entry.block === block ? entry.round : 0;
}

type FileTemplate = {
  name: string;
  kind: "ipfs" | "arweave";
  /** The mapping function the manifest names. */
  handler: string;
  /** The `entities` the manifest lists: all a file data source may touch. */
  entities: Set<string>;
  mapping: Record<string, any>;
};

/** The table that records which file data sources have run (`FILE_DATA_SOURCE_ENTITY`, Rust). */
const FILE_DATA_SOURCE_ENTITY = "EnvioFileDataSource";
/** A mapping that makes its file data sources create more, forever, is stopped here. */
const MAX_FILES_PER_TRIGGER = 10_000;

/**
 * Runs the file data sources a handler created, right after it, in the block
 * that created them (graph-node runs them when their file arrives, which is
 * some later block; running at the creating block is deterministic, and
 * entities a file handler writes are in the store the moment the creating block
 * is). Each runs in isolation, as graph-node's do:
 *
 * - only once per template, file and context (a record in its own table, so a
 *   reorg or a restart doesn't run it twice, and a second create is ignored);
 * - it may touch only the entities its manifest entry lists, and sees only what
 *   it wrote itself — never a chain entity (`graph-ts.ts` store);
 * - a file that isn't there after `ENVIO_SUBGRAPH_FILE_ATTEMPTS` attempts
 *   skips the handler, with a warning (graph-node polls on, with backoff);
 * - a CID that doesn't parse is ignored, as graph-node ignores it.
 *
 * A file handler may itself create file data sources; those run after it.
 * During preload only the files are fetched, so a batch's files download
 * concurrently and the execute pass finds them cached.
 */
function makeFileRunner(
  fileTemplates: Map<string, FileTemplate>,
  hosts: ReturnType<typeof makeHostEffects>,
  schema: SubgraphSchema,
) {
  return async (parent: Scope | undefined, context: any): Promise<void> => {
    if (!parent?.fileCreates || parent.fileCreates.size === 0) return;
    const queue: FileCreate[] = [...parent.fileCreates.values()];
    for (let index = 0; index < queue.length; index++) {
      if (index >= MAX_FILES_PER_TRIGGER) {
        throw new Error(
          `A handler created more than ${MAX_FILES_PER_TRIGGER} file data sources from one trigger; ` +
            "a file data source that keeps creating more is not going to stop.",
        );
      }
      const create = queue[index];
      const template = fileTemplates.get(create.template);
      if (!template) continue;
      const path =
        template.kind === "ipfs" ? normalizeIpfsPath(create.source) : create.source.trim().replace(/^\//, "") || null;
      if (path === null) {
        context.log.warn(
          `${template.name}.create() was given "${create.source}", which isn't a content id; ignoring the file data source.`,
        );
        continue;
      }
      const input = `${template.kind}:${path}`;
      if (context.isPreload) {
        await context.effect(hosts.fileData, input);
        continue;
      }
      const handler = template.mapping[template.handler];
      if (typeof handler !== "function") continue;

      const doneId = createHash("sha1").update(fileCreateId(create)).digest("hex");
      const done = context[schema.entityAccessors[FILE_DATA_SOURCE_ENTITY]];
      if (await done.get(doneId)) continue;

      const content: string | null = await context.effect(hosts.fileData, input);
      if (content === null) {
        context.log.warn(`${template.name}: ${input} isn't available; its handler is skipped.`);
        continue;
      }
      done.set({ id: doneId });

      const ran: { scope?: Scope } = {};
      await context.runSync(() =>
        runInScope(
          (ran.scope = {
            context,
            event: parent.event,
            mode: "handler",
            schema,
            dataSource: { ...parent.dataSource, name: template.name, address: path, context: {} },
            registered: new Set(),
            blockNumber: parent.blockNumber,
            position: parent.position,
            mappingExports: template.mapping,
            file: {
              kind: template.kind,
              entities: template.entities,
              written: new Set(),
              context: create.context,
            },
          }),
          () => handler(decodeBase64(content)),
        ),
      );
      if (ran.scope?.fileCreates) queue.push(...ran.scope.fileCreates.values());
    }
  };
}

export async function registerSubgraph(config: SubgraphConfig): Promise<void> {
  legacyNulls = [...config.dataSources, ...config.templates].some((source) => {
    const [major, minor, patch] = (source.apiVersion ?? "").split(".").map(Number);
    return major === 0 && minor === 0 && patch < 5;
  });
  setLegacyNullOperands(legacyNulls);
  installResolveHook(config.root);
  resetRpcClients();
  resetCallBackends();
  // The chain's sources read calls only when a handler wants them.
  installCallSource(fetchCalls, config.rpcUrls ?? []);
  resetRegisterStore();
  registeredTemplates.clear();
  blockTemplates.clear();
  for (const template of config.templates) {
    if (template.blockHandlers.length > 0) blockTemplates.add(template.name);
  }
  registrationRounds.clear();
  unregisteredCreates.clear();
  announceWhereToQuery();
  if (config.graftNotice) warn(config.graftNotice);
  if (config.graft && process.env.ENVIO_SUBGRAPH_GRAFT_CHECK !== "off") {
    const ownStarts = config.dataSources.flatMap((source) =>
      source.startBlock === undefined ? [] : [source.startBlock],
    );
    // Best effort and not waited on: an offline box or an unpinned base says nothing.
    void graftBaseNotice(config.graft, ownStarts).then(
      (notice) => notice && warn(notice),
      () => undefined,
    );
  }

  // One effect for every contract call: envio already batches and dedupes
  // effect calls in preload, and the block number in the input is what keeps
  // a cached result tied to the state the mapping saw.
  const rpcUrls = config.rpcUrls ?? [];
  const callEffect = makeCallEffect(rpcUrls, (encoded) => {
    const hit = registerCache.get(`envio_subgraph_eth_call\u0000${encoded}`);
    return hit && "value" in hit ? (hit.value as string) : undefined;
  });
  const hosts = makeHostEffects(rpcUrls, config.blockHeaderLag ?? {});
  const callSync = (effect: unknown, input: unknown, what: string) => {
    const scope = currentScope();
    void what;
    if (scope.mode === "register") {
      return registerHostSync(scope, effect as Effect, input);
    }
    return scope.context.effectSync(effect, input);
  };

  installHosts({
    ipfsCat: (hash) => callSync(hosts.ipfsCat, normalizeIpfsPath(hash) ?? hash, "ipfs.cat()"),
    ipfsMap: (hash, callback, userData, flags) => {
      const scope = currentScope();
      // graph-node: `ensure!(flags.contains("json"), "Flags must contain 'json'")`.
      if (!flags.includes("json")) throw new Error("ipfs.map(): Flags must contain 'json'");
      const fn = scope.mappingExports[callback];
      if (typeof fn !== "function") {
        throw new Error(
          `ipfs.map() names the callback "${callback}", which the mapping doesn't export.`,
        );
      }
      const encoded: string | null = callSync(hosts.ipfsCat, normalizeIpfsPath(hash) ?? hash, "ipfs.map()");
      if (encoded === null) return;
      const body = Buffer.from(encoded, "base64").toString("utf8");
      // One JSON value per line, each handed to the callback in turn; a line
      // that isn't JSON, or a callback that throws, fails the call, as
      // graph-node's `ipfs_map: callback '<name>' failed when processing file`.
      const lines = body.split("\n");
      for (let index = 0; index < lines.length; index++) {
        const line = lines[index];
        if (line.trim() === "") continue;
        try {
          fn(jsonFromString(line), userData);
        } catch (error) {
          // A suspend is the sync bridge asking for a replay, not a failure.
          if (isBridgeSignal(error) || !(error instanceof Error)) throw error;
          error.message = `ipfs_map: callback '${callback}' failed when processing file '${hash}' (line ${index + 1}): ${error.message}`;
          throw error;
        }
      }
    },
    arweaveData: (txId) => callSync(hosts.arweaveData, txId, "arweave.transactionData()"),
    ensName: (hash) => callSync(hosts.ensName, hash, "ens.nameByHash()"),
    getBalance: (address) =>
      callSync(
        hosts.getBalance,
        JSON.stringify({ address, blockNumber: currentScope().blockNumber }),
        "ethereum.getBalance()",
      ),
    hasCode: (address) =>
      callSync(
        hosts.hasCode,
        JSON.stringify({ address, blockNumber: currentScope().blockNumber }),
        "ethereum.hasCode()",
      ),
    blockTimestamp: (blockNumber) =>
      callSync(hosts.blockTimestamp, blockNumber, "block.timestamp"),
    blockHeader: (blockNumber) => callSync(hosts.blockHeader, blockNumber, "block header"),
    receiptLogs: (transaction) => callSync(hosts.receiptLogs, transaction, "event.receipt.logs"),
  });

  // Reads the scope rather than closing over one context: register passes for
  // the items in a batch run concurrently, and this hook is process-wide.
  installRegisterMissHook(onRegisterMiss);

  installRegisterHook((templateName, address) => {
    const accessor = config.contractAccessors[templateName];
    if (accessor === undefined) throw unknown(`the template ${templateName}`, "a mapping handler");
    const scope = currentScope();
    scope.context.chain[accessor].add(address);
    if (blockTemplates.has(templateName)) {
      rememberInstance(scope.dataSource.chainId, templateName, address, scope.blockNumber);
    }
    const key = `${scope.dataSource.chainId}:${templateName}:${address.toLowerCase()}`;
    registeredTemplates.delete(key);
    registeredTemplates.add(key);
    if (!registrationRounds.has(key)) {
      const { dataSource, blockNumber } = scope;
      const round = roundOf(dataSource.chainId, dataSource.name, dataSource.address, blockNumber) + 1;
      registrationRounds.set(key, { block: blockNumber, round });
    }
    if (registeredTemplates.size > REGISTERED_TEMPLATES_LIMIT) {
      const oldest = registeredTemplates.values().next().value!;
      registeredTemplates.delete(oldest);
      registrationRounds.delete(oldest);
    }
  });

  // Only the register pass registers an address, at fetch time. A create it
  // didn't make — it threw on an entity no register pass saved, or there is
  // none, as for a polling block handler — loses that template's events.
  installHandlerCreateHook((templateName, address) => {
    const scope = currentScope();
    if (scope.context.isPreload) return;
    const key = `${scope.dataSource.chainId}:${templateName}:${address.toLowerCase()}`;
    if (registeredTemplates.has(key) || unregisteredCreates.has(key)) return;
    unregisteredCreates.add(key);
    warn(
      `Envio Subgraph: data source "${scope.dataSource.name}" created the template "${templateName}" for ` +
        `${address.toLowerCase()} at block ${scope.blockNumber} in its handler, but no register pass did, so the ` +
        `events of that ${templateName} are not indexed. A register pass reads only what earlier register passes ` +
        "saved. Please open an issue: https://github.com/enviodev/hyperindex/issues",
    );
  });

  const abiFiles = new Map<string, string>();
  for (const source of [...config.dataSources, ...config.templates]) {
    for (const [name, file] of Object.entries(source.abis ?? {})) {
      if (!abiFiles.has(name)) abiFiles.set(name, path.resolve(config.root, file));
    }
  }
  const legacySignatures = new Map<string, string>();
  installLegacySignatureHook((abiName, functionName) => {
    const key = `${abiName}.${functionName}`;
    const known = legacySignatures.get(key);
    if (known) return known;
    const file = abiFiles.get(abiName);
    const signature = file ? functionSignature(JSON.parse(readFileSync(file, "utf8")), functionName) : null;
    if (!signature) {
      throw new Error(
        `Envio Subgraph: the mapping calls ${key} by name, and the manifest's ABI "${abiName}" has no function ` +
          `${functionName}. graph-node fails the call the same way.`,
      );
    }
    legacySignatures.set(key, signature);
    return signature;
  });

  installCallHook((call) => {
    const scope = currentScope();
    void scope;
    const encoded = JSON.stringify({
      chainId: currentScope().dataSource.chainId,
      address: call.contractAddress.toHexString(),
      signature: call.functionSignature,
      args: call.functionParams.map((param: any) => encodeArg(ethereumValueToJs(param))),
      blockNumber: scope.blockNumber,
    });
    const raw = callSync(callEffect, encoded, `the contract call ${call.functionSignature}`);
    if (raw === null) {
      return { reverted: true, value: null };
    }
    const output = JSON.parse(raw);
    return {
      reverted: output.reverted,
      value: output.values === null ? null : output.values.map(decodeArg),
    };
  });

  const schema: SubgraphSchema = {
    timestampFields: config.timestampFields ?? {},
    bytesIdEntities: config.bytesIdEntities ?? [],
    entityListFields: config.entityListFields ?? {},
    entityFields: config.entityFields ?? {},
    entityRefFields: config.entityRefFields ?? {},
    entityFieldTypes: config.entityFieldTypes ?? {},
    entityAccessors: config.entityAccessors,
    timeseriesEntities: config.timeseriesEntities ?? [],
    aggregations: config.aggregations ?? [],
  };
  const secondsOf = (blockNumber: number, given: unknown) => () =>
    given !== undefined && given !== null
      ? Number(given)
      : Number(callSync(hosts.blockTimestamp, blockNumber, "block.timestamp"));
  // Aggregations roll up when a block's time passes a bucket's end, so every
  // handler checks first; the timeseries it saves carry the block's time.
  const startRun = (scope: Scope) => {
    scope.timeseriesSequence = 0;
    // A replayed round creates its file data sources again.
    scope.fileCreates = undefined;
    if (schema.aggregations.length > 0) {
      advanceRollup(scope, BigInt(scope.blockSeconds!()) * 1_000_000n);
    }
  };

  // Before any mapping is imported: Node caches a failed module resolution for
  // the life of the process, so generating after the import has already failed
  // wouldn't help.
  const sources = [...config.dataSources, ...config.templates];
  const generated = generatedDir(
    config.root,
    sources.map((source) => source.mappingFile),
  );
  const fetchedModules = await fetchMappingPackages(
    config.root,
    missingMappingPackages(
      config.root,
      sources.map((source) => source.mappingFile),
    ),
  );
  fetchedModulesParent = fetchedModules
    ? pathToFileURL(path.join(path.dirname(fetchedModules), "resolve-from.mjs")).href
    : null;
  await ensureGeneratedCode(
    config.root,
    generated,
    config.manifestFile,
    sources.map((source) => source.mappingFile),
  );

  if (config.isDev) {
    await typeCheckMappings(config.root, config.manifestFile);
  }

  // A file template has no contract: nothing is registered for it, so it takes
  // no part in the create analysis or the folding below.
  const isFile = (source: DataSource) => source.kind === "fileIpfs" || source.kind === "fileArweave";
  const templateNames = new Set(
    config.templates.filter((template) => !isFile(template)).map((template) => template.name),
  );
  const fileTemplates = new Map<string, FileTemplate>();
  for (const source of config.templates) {
    if (!isFile(source)) continue;
    const mapping = await loadMapping(config.root, generated, source.mappingFile, {
      context: null,
      event: null,
      mode: "handler",
      schema,
      dataSource: { name: source.name, address: "", chainId: 0, network: "", context: {} },
      registered: new Set(),
      blockNumber: 0,
      mappingExports: {},
    });
    await indexEventClasses();
    fileTemplates.set(source.name, {
      name: source.name,
      kind: source.kind === "fileArweave" ? "arweave" : "ipfs",
      handler: source.eventHandlers[0]?.handler ?? "",
      entities: new Set(source.entities ?? []),
      mapping,
    });
  }
  installFileTemplates(new Map([...fileTemplates].map(([name, template]) => [name, template.kind])));
  const runFileDataSources = makeFileRunner(fileTemplates, hosts, schema);

  // A template sharing a data source's name is folded into its envio contract,
  // so both sets of handlers fire for every address of it. graph-node runs the
  // data source's for its own address and the template's for the ones it
  // created, so each is gated to its side.
  const staticAddresses = new Map<string, Set<string>>();
  for (const source of config.dataSources) {
    if (!source.address || !templateNames.has(source.name)) continue;
    const addresses = staticAddresses.get(source.name) ?? new Set();
    addresses.add(`${source.chainId}:${source.address.toLowerCase()}`);
    staticAddresses.set(source.name, addresses);
  }
  const ownerOf = (source: DataSource) => {
    const addresses = staticAddresses.get(source.name);
    if (!addresses) return () => true;
    return (event: any) =>
      addresses.has(`${event.chainId}:${String(event.srcAddress).toLowerCase()}`) !== source.isTemplate;
  };

  // A `once` block handler sets up what the event handlers then load — Venus
  // saves its Comptroller there, and getOrCreateMarket reads it before it
  // creates the VToken template. Block handlers get no register pass of their
  // own, so each runs once in register mode, at its block, before the first
  // register pass of its chain reads the register store.
  const onceHandlers = new Map<number, ((context: any) => Promise<void>)[]>();
  const primed = new Map<number, Promise<void>>();
  const primeOnceHandlers = (chainId: number, context: any) => {
    let done = primed.get(chainId);
    if (!done) {
      done = (async () => {
        for (const run of onceHandlers.get(chainId) ?? []) await run(context);
      })();
      primed.set(chainId, done);
    }
    return done;
  };

  for (const source of sources) {
    if (source.kind !== "contract") continue;
    const mapping = await loadMapping(config.root, generated, source.mappingFile, {
      context: null,
      event: null,
      mode: "handler",
      schema,
      dataSource: {
        name: source.name,
        address: source.address ?? "",
        chainId: source.chainId ?? 0,
        network: source.network ?? "",
        context: source.context ?? {},
      },
      registered: new Set(),
      blockNumber: source.startBlock ?? 0,
      mappingExports: {},
    });

    await indexEventClasses();
    const owns = ownerOf(source);
    // graph-node runs none of a data source's handlers past its endBlock
    // (`has_expired`), while its chain and every template instance go on.
    const live = (event: any) =>
      source.isTemplate || source.endBlock === undefined || event.block.number <= source.endBlock;
    // After codegen, so the analysis can follow the mapping into
    // `generated/templates.ts`.
    const creating = new Set<string>(
      templateNames.size === 0
        ? []
        : registerEveryHandler
          ? [...source.eventHandlers, ...(source.callHandlers ?? []), ...source.blockHandlers].map(
              (handler) => handler.handler,
            )
          : subgraphCreatingHandlers(
              path.resolve(config.root, source.mappingFile),
              [...source.eventHandlers, ...(source.callHandlers ?? []), ...source.blockHandlers].map(
                (handler) => handler.handler,
              ),
            ),
    );
    // graph-node matches a data source without `source.address` against every
    // contract's logs — ENS's Resolver is one data source for every resolver
    // anyone deploys. Nothing would ever register an address for it here.
    const wildcard = !source.isTemplate && !source.address;

    for (const handler of source.eventHandlers) {
      const fn = mapping[handler.handler];
      // `graph build` doesn't check that a named handler is exported — Aave's
      // mainnet manifest names one its mappings renamed years ago — so a
      // subgraph that deploys today would be refused here for a stale line the
      // event it names never reaches.
      if (typeof fn !== "function") continue;

      const kind: EventKind = {
        location: `data source "${source.name}" → "${handler.name}"`,
        inputs: handler.inputs ?? [],
        hasReceipt: handler.receipt ?? false,
      };
      // Built as the generated class the handler declares, when it declares
      // one: its `params` getters are graph codegen's own.
      const EventClass = mapping[EVENT_CLASSES_EXPORT]?.[handler.handler] ?? eventClasses.get(fn) ?? ethereum.Event;
      const makeEvent = (event: unknown) => makeGraphEvent(event, kind, EventClass);

      const makeScope = (event: any, context: any, mode: Scope["mode"]): Scope => ({
        context,
        event,
        mode,
        schema,
        dataSource: {
          name: source.name,
          address: event.srcAddress,
          chainId: event.chainId,
          network: source.network ?? "",
          context: contextOf(event.chainId, source.name, event.srcAddress) ?? source.context ?? {},
        },
        registered: new Set(),
        blockNumber: event.block.number,
        blockSeconds: secondsOf(event.block.number, event.block.timestamp),
        position:
          event.block.number * POSITION_BLOCK +
          Math.min(roundOf(event.chainId, source.name, event.srcAddress, event.block.number), 15) * ROUND_SPAN +
          event.logIndex,
        mappingExports: mapping,
      });

      const where = topicFilter(handler);

      indexer.onEvent(
        { contract: config.contractAccessors[source.name], event: handler.name, where, wildcard },
        async ({ event, context }: any) => {
          if ((skipPreload && context.isPreload) || !owns(event) || !live(event)) return;
          const scope = makeScope(event, context, "handler");
          await runSyncCounted(context, () =>
            runInScope(scope, () => {
              startRun(scope);
              // A fresh event per run: the handler is replayed while it waits on
              // calls, and one that edits its event (Seamless rewrites
              // `event.parameters[2]` into the newer shape) must not meet its own
              // edit on the next round.
              return fn(makeEvent(event));
            }),
          );
          await runFileDataSources(scope, context);
        },
      );

      // `dataSource.create` has to reach envio's contractRegister, which runs
      // at fetch time — before any entity exists. The same mapping reruns in
      // register mode, where writes and logs are no-ops and reads are null —
      // only when its code can reach a create (`subgraph/creates.rs`): the
      // rerun costs every contract call the handler makes on the way.
      if (creating.has(handler.handler)) {
        indexer.contractRegister(
          { contract: config.contractAccessors[source.name], event: handler.name, where, wildcard },
          async ({ event, context }: any) => {
            if (!owns(event) || !live(event)) return;
            await primeOnceHandlers(event.chainId, context);
            const scope = makeScope(event, context, "register");
            scope.slot = await registerSlots.acquire(scope.position ?? 0);
            const { pass, settle } = startRegisterPass(event.chainId, scope.position ?? 0);
            scope.pass = pass;
            try {
              await runRegisterRounds(scope, () => fn(makeEvent(event)));
            } finally {
              settle();
              scope.slot?.release();
            }
          },
        );
      }
    }

    // A call is an envio item like a log: the source that reads traces produces
    // it, and everything between the fetch and here — partitioning, order, the
    // register pass, rollback — treats it as one. Its params carry the raw
    // calldata and return data, decoded against the function's ABI on demand.
    const callScope = (event: any, context: any, mode: Scope["mode"]): Scope => ({
      context,
      event,
      mode,
      schema,
      dataSource: {
        name: source.name,
        address: event.srcAddress,
        chainId: event.chainId,
        network: source.network ?? "",
        context: source.context ?? {},
      },
      registered: new Set(),
      blockNumber: event.block.number,
      blockSeconds: secondsOf(event.block.number, event.block?.timestamp),
      position: callPosition(event),
      mappingExports: mapping,
    });

    const registerCallHandler = (
      trigger: string,
      handlerName: string,
      kind: CallKind | null,
      run: (event: any, call: unknown) => unknown,
    ) => {
      const fn = mapping[handlerName];
      if (typeof fn !== "function") return;
      const CallClass = mapping[EVENT_CLASSES_EXPORT]?.[handlerName] ?? eventClasses.get(fn) ?? ethereum.Call;
      const make = (event: any) =>
        kind === null ? makeCallBlock(event.block) : makeGraphCall(event, kind, CallClass);
      const target = { contract: config.contractAccessors[source.name], event: trigger };

      indexer.onEvent(target, async ({ event, context }: any) => {
        if ((skipPreload && context.isPreload) || !owns(event) || !live(event)) return;
        // graph-node skips a call whose calldata doesn't decode against the
        // function, with a warning — a proxy's fallback shares selectors.
        if (kind !== null && !callInputDecodes(kind, event.params.callInput)) {
          if (!context.isPreload) {
            context.log.warn(
              `Skipping a call to ${event.srcAddress} in transaction ${event.transaction.hash}: its input does not decode as ${kind.location}`,
            );
          }
          return;
        }
        const scope = callScope(event, context, "handler");
        // A fresh call per run, as for events: a replayed handler must not meet
        // its own edits.
        await runSyncCounted(context, () =>
          runInScope(scope, () => {
            startRun(scope);
            return run(event, make(event));
          }),
        );
        await runFileDataSources(scope, context);
      });

      if (creating.has(handlerName)) {
        indexer.contractRegister(target, async ({ event, context }: any) => {
          if (!owns(event) || !live(event)) return;
          if (kind !== null && !callInputDecodes(kind, event.params.callInput)) return;
          await primeOnceHandlers(event.chainId, context);
          const scope = callScope(event, context, "register");
          scope.slot = await registerSlots.acquire(scope.position ?? 0);
          const { pass, settle } = startRegisterPass(event.chainId, scope.position ?? 0);
          scope.pass = pass;
          try {
            await runRegisterRounds(scope, () => run(event, make(event)));
          } finally {
            settle();
            scope.slot?.release();
          }
        });
      }
    };

    for (const handler of source.callHandlers ?? []) {
      registerCallHandler(
        handler.name,
        handler.handler,
        {
          location: `data source "${source.name}" → callHandlers → "${handler.function}"`,
          inputs: handler.inputs ?? [],
          outputs: handler.outputs ?? [],
        },
        (_, call) => mapping[handler.handler](call),
      );
    }

    for (const handler of source.blockHandlers) {
      // Once per call to the data source's address in the block, after the
      // block's logs and calls — graph-node's `WithCallTo` block trigger.
      if (handler.filter === "call" && handler.callEvent) {
        registerCallHandler(handler.callEvent, handler.handler, null, (_, block) =>
          mapping[handler.handler](block),
        );
      }
    }

    for (const handler of source.blockHandlers) {
      if (handler.filter === "call") continue;
      const fn = mapping[handler.handler];
      if (typeof fn !== "function") continue;
      const start = source.startBlock ?? 0;
      if (handler.filter === "once" && templateNames.size > 0 && source.chainId !== undefined) {
        const location = `data source "${source.name}" → "${handler.handler}"`;
        const runs = onceHandlers.get(source.chainId) ?? [];
        runs.push((context) =>
          runRegisterRounds(
            {
              context,
              event: { number: start },
              mode: "register",
              schema,
              dataSource: {
                name: source.name,
                address: source.address ?? "",
                chainId: source.chainId ?? 0,
                network: source.network ?? "",
                context: source.context ?? {},
              },
              registered: new Set(),
              blockNumber: start,
              // Ahead of every log of its block, as graph-node runs it.
              position: start * POSITION_BLOCK - 1,
              mappingExports: mapping,
            },
            () => fn(makeBlockHandlerBlock(start, location)),
          ),
        );
        onceHandlers.set(source.chainId, runs);
      }
      // A template's instances all exist from the first static source on its
      // chain, and the handler runs once per instance from its creation block.
      const chainStarts = config.dataSources
        .filter((other) => other.chainId === source.chainId)
        .map((other) => other.startBlock ?? 0);
      const first = source.isTemplate ? Math.min(...chainStarts, 0 + (chainStarts.length === 0 ? 0 : Number.MAX_SAFE_INTEGER)) : start;
      const blocks =
        handler.filter === "once"
          ? { _gte: start, _lte: start }
          : source.endBlock === undefined
            ? { _gte: first, _every: handler.filter.every }
            : { _gte: start, _lte: source.endBlock, _every: handler.filter.every };
      indexer.onBlock(
        {
          name: `${source.name}_${handler.handler}`,
          where: ({ chain }: { chain: { id: number } }) =>
            chain.id === source.chainId && { block: { number: blocks } },
        },
        async ({ block, context }: any) => {
          if (skipPreload && context.isPreload) return;
          const graphBlock = makeBlockHandlerBlock(
            block.number,
            `data source "${source.name}" → "${handler.handler}"`,
          );
          const addresses = source.isTemplate ? instancesAt(block.chainId ?? source.chainId, source.name, block.number) : [source.address ?? ""];
          for (const address of addresses) {
            const scope: Scope = {
              context,
              event: block,
              mode: "handler",
              schema,
              dataSource: {
                name: source.name,
                address,
                chainId: source.chainId ?? 0,
                network: source.network ?? "",
                context: (source.isTemplate ? contextOf(source.chainId ?? 0, source.name, address) : undefined) ?? source.context ?? {},
              },
              registered: new Set(),
              blockNumber: block.number,
              blockSeconds: secondsOf(block.number, block.timestamp),
              mappingExports: mapping,
            };
            await runSyncCounted(context, () =>
              runInScope(scope, () => {
                startRun(scope);
                return fn(graphBlock);
              }),
            );
            await runFileDataSources(scope, context);
          }
        },
      );
    }
  }
}
