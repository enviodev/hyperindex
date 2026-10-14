/**
 * Turns a translated manifest into envio registrations.
 *
 * Each manifest handler becomes an `onEvent` / `onBlock` / `contractRegister`
 * wrapper that runs the mapping synchronously inside `runSync`: reads try the
 * in-memory state first, a miss schedules the async op and suspends, and the
 * replay loop reruns the mapping once what it asked for has landed.
 */

import { existsSync, readFileSync } from "node:fs";
import { registerHooks } from "node:module";
import { fileURLToPath, pathToFileURL } from "node:url";
import path from "node:path";
import { indexer } from "../Api.res.mjs";
import { subgraphCreatingHandlers, subgraphFileToJavascript } from "../Core.res.mjs";
import { currentScope, runInScope, type Scope, type SubgraphSchema } from "./scope.ts";
import {
  Address,
  assemblyScriptPrimitives,
  BigInt as GraphBigInt,
  Bytes,
  changetype,
  retagChangetype,
  retagEach,
  installCallHook,
  installHosts,
  installRegisterHook,
  ethereum,
  type EventInput,
  type EventKind,
  json as jsonNamespace,
  makeBlockHandlerBlock,
  makeEvent as makeGraphEvent,
  commitRegisterWrites,
  resetRegisterStore,
  POSITION_BLOCK,
  ethereumValueToJs,
} from "./graph-ts.ts";
import { encodeArg, decodeArg, makeCallEffect } from "./calls.ts";
import { resetRpcClients } from "./rpc.ts";
import {
  EVENT_CLASSES_EXPORT,
  OPERATORS_HELPER,
  RETAG_EACH_HELPER,
  RETAG_HELPER,
  operators,
} from "./assemblyscript.ts";
import { makeHostEffects } from "./hosts.ts";
import { ensureGeneratedCode, generatedDir, missingGeneratedCode, typeCheckMappings } from "./graph-cli.ts";
import { unknown, unsupported } from "./errors.ts";

const SHIM_URL = new URL("./graph-ts.ts", import.meta.url).href;

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
/** As the translator serialises its `BlockFilter`. */
type BlockHandler = { handler: string; filter: { every: number } | "once" };
type DataSource = {
  kind: string;
  name: string;
  network?: string;
  chainId?: number;
  address?: string;
  startBlock?: number;
  endBlock?: number;
  mappingFile: string;
  eventHandlers: EventHandler[];
  blockHandlers: BlockHandler[];
  context?: Record<string, { type: string; data: string }>;
  isTemplate: boolean;
};
type SubgraphConfig = {
  specVersion: string;
  dataSources: DataSource[];
  templates: DataSource[];
  declaresEthCalls: boolean;
  /** The config's contract name for each data source and template. */
  contractAccessors: Record<string, string>;
  root: string;
  rpcUrls: string[];
  isDev: boolean;
} & SubgraphSchema;

const AS_DATE = Symbol.for("envio.subgraph.date");

let hooksInstalled = false;
let projectRoot: string | null = null;
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
      const resolved = nextResolve(specifier, context);
      // A subgraph project's package.json has no `type`, so its mappings and
      // its `generated/` would load as CommonJS and reach the shim — a real ES
      // module — through `require()`, which Node refuses inside a cycle. They
      // are ES modules; saying so is what lets them import it.
      if (projectRoot && resolved?.url?.startsWith(projectRoot)) {
        return { ...resolved, format: "module" };
      }
      return resolved;
    },
    // Taken over before any other loader sees the file: a TypeScript
    // transpiler would refuse AssemblyScript it has no reason to accept, and
    // would strip `changetype`'s type argument before it could be read.
    load(url: string, context: any, nextLoad: any) {
      if (
        !projectRoot ||
        !url.startsWith(projectRoot) ||
        url.includes("/node_modules/") ||
        !url.endsWith(".ts")
      ) {
        return nextLoad(url, context);
      }
      const file = fileURLToPath(url);
      projectModules.add(url);
      return {
        format: "module",
        source: subgraphFileToJavascript(readFileSync(file, "utf8"), file),
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
    return await runInScope(scope, () => import(url));
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
        commitRegisterWrites(scope);
        return;
      }
      suspended = true;
    }
    const awaiting = scope.awaiting;
    if (!suspended) {
      commitRegisterWrites(scope);
      return;
    }
    if (!awaiting || awaiting.length === 0) {
      throw new Error(
        "Envio Subgraph suspended the register pass with nothing to wait for. " +
          "Please open an issue: https://github.com/enviodev/hyperindex/issues",
      );
    }
    await Promise.all(awaiting);
  }
  throw new Error(
    `Envio Subgraph replayed a mapping's dataSource.create() pass ${maxRegisterRounds} times ` +
      "without it settling. This usually means the mapping isn't deterministic across reruns.",
  );
}

export async function registerSubgraph(config: SubgraphConfig): Promise<void> {
  installResolveHook(config.root);
  resetRpcClients();
  resetRegisterStore();

  // One effect for every contract call: envio already batches and dedupes
  // effect calls in preload, and the block number in the input is what keeps
  // a cached result tied to the state the mapping saw.
  const rpcUrls = config.rpcUrls ?? [];
  const callEffect = makeCallEffect(rpcUrls, (encoded) => {
    const hit = registerCache.get(`envio_subgraph_eth_call\u0000${encoded}`);
    return hit && "value" in hit ? (hit.value as string) : undefined;
  });
  const hosts = makeHostEffects(rpcUrls);
  const callSync = (effect: unknown, input: unknown, what: string) => {
    const scope = currentScope();
    void what;
    if (scope.mode === "register") {
      return registerHostSync(scope, effect as Effect, input);
    }
    return scope.context.effectSync(effect, input);
  };

  installHosts({
    ipfsCat: (hash) => callSync(hosts.ipfsCat, hash, "ipfs.cat()"),
    ipfsMap: (hash, callback, userData, flags) => {
      const scope = currentScope();
      const fn = scope.mappingExports[callback];
      if (typeof fn !== "function") {
        throw new Error(
          `ipfs.map() names the callback "${callback}", which the mapping doesn't export.`,
        );
      }
      const encoded: string | null = callSync(hosts.ipfsCat, hash, "ipfs.map()");
      if (encoded === null) return;
      const body = Buffer.from(encoded, "base64").toString("utf8");
      for (const line of body.split("\n")) {
        if (line.trim() === "") continue;
        fn(jsonFromString(line), userData);
      }
      void flags;
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
  });

  // Reads the scope rather than closing over one context: register passes for
  // the items in a batch run concurrently, and this hook is process-wide.
  installRegisterHook((templateName, address) => {
    const accessor = config.contractAccessors[templateName];
    if (accessor === undefined) throw unknown(`the template ${templateName}`, "a mapping handler");
    currentScope().context.chain[accessor].add(address);
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
  };

  // Before any mapping is imported: Node caches a failed module resolution for
  // the life of the process, so generating after the import has already failed
  // wouldn't help.
  const sources = [...config.dataSources, ...config.templates];
  const generated = generatedDir(
    config.root,
    sources.map((source) => source.mappingFile),
  );
  await ensureGeneratedCode(config.root, generated);

  if (config.isDev) {
    await typeCheckMappings(config.root);
  }

  const templateNames = new Set(config.templates.map((template) => template.name));

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
    // After codegen, so the analysis can follow the mapping into
    // `generated/templates.ts`.
    const creating = new Set<string>(
      templateNames.size === 0
        ? []
        : registerEveryHandler
          ? source.eventHandlers.map((handler) => handler.handler)
          : subgraphCreatingHandlers(
              path.resolve(config.root, source.mappingFile),
              source.eventHandlers.map((handler) => handler.handler),
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
          context: source.context ?? {},
        },
        registered: new Set(),
        blockNumber: event.block.number,
        position: event.block.number * POSITION_BLOCK + event.logIndex,
        mappingExports: mapping,
      });

      const where = topicFilter(handler);

      indexer.onEvent(
        { contract: config.contractAccessors[source.name], event: handler.name, where, wildcard },
        async ({ event, context }: any) => {
          if ((skipPreload && context.isPreload) || !owns(event)) return;
          const graphEvent = makeEvent(event);
          await (context as any).runSync(() =>
            runInScope(makeScope(event, context, "handler"), () => fn(graphEvent)),
          );
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
            if (!owns(event)) return;
            await primeOnceHandlers(event.chainId, context);
            const graphEvent = makeEvent(event);
            await runRegisterRounds(makeScope(event, context, "register"), () => fn(graphEvent));
          },
        );
      }
    }

    for (const handler of source.blockHandlers) {
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
      const blocks =
        handler.filter === "once"
          ? { _gte: start, _lte: start }
          : { _gte: start, _every: handler.filter.every };
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
          await (context as any).runSync(() =>
            runInScope(
              {
                context,
                event: block,
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
                blockNumber: block.number,
                mappingExports: mapping,
              },
              () => fn(graphBlock),
            ),
          );
        },
      );
    }
  }
}
