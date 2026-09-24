/**
 * Turns a translated manifest into envio registrations.
 *
 * Each manifest handler becomes an `onEvent` / `onBlock` / `contractRegister`
 * wrapper that runs the mapping synchronously inside `runSync`: reads try the
 * in-memory state first, a miss schedules the async op and suspends, and the
 * replay loop reruns the mapping once what it asked for has landed.
 */

import { execFileSync } from "node:child_process";
import {
  existsSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { registerHooks } from "node:module";
import { fileURLToPath, pathToFileURL } from "node:url";
import path from "node:path";
import { indexer } from "../Api.res.mjs";
import { subgraphFileToJavascript } from "../Core.res.mjs";
import { currentScope, runInScope, type Scope, type SubgraphSchema } from "./scope.ts";
import {
  Address,
  assemblyScriptPrimitives,
  BigInt as GraphBigInt,
  Bytes,
  changetype,
  retagChangetype,
  installCallHook,
  installHosts,
  installRegisterHook,
  ethereum,
  type EventInput,
  type EventKind,
  json as jsonNamespace,
  makeBlockHandlerBlock,
  ethereumValueToJs,
} from "./graph-ts.ts";
import { encodeArg, decodeArg, makeCallEffect, resetClients } from "./calls.ts";
import { DIVIDE_HELPER, EVENT_CLASSES_EXPORT, RETAG_HELPER, integerDivision } from "./assemblyscript.ts";
import { makeHostEffects } from "./hosts.ts";
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

type EventHandler = {
  event: string;
  name: string;
  handler: string;
  receipt: boolean;
  inputs?: EventInput[];
};
type BlockHandler = { handler: string; filter: { Every: number } | "Once" | any };
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

let hooksInstalled = false;
let projectRoot: string | null = null;

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
        specifier.startsWith("@graphprotocol/graph-ts/")
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
  globals[DIVIDE_HELPER] ??= integerDivision;
  globals[RETAG_HELPER] ??= retagChangetype;
  globals.assert ??= (value: unknown, message?: string) => {
    if (!value) throw new Error(message ?? "assertion failed");
    return value;
  };
  for (const [name, namespace] of Object.entries(assemblyScriptPrimitives)) {
    globals[name] ??= namespace;
  }
}

function blockInterval(handler: BlockHandler): { every?: number; once?: boolean } {
  const filter = handler.filter as any;
  if (filter === "Once" || filter?.Once !== undefined) return { once: true };
  if (typeof filter?.Every === "number") return { every: filter.Every };
  return { every: 1 };
}

async function loadMapping(
  root: string,
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
    if (/Cannot find (module|package)/.test(message) && message.includes("generated")) {
      ensureGeneratedCode(root, { required: true });
    }
    // An unknown named import fails at Node's ESM link step, before any Proxy
    // in the shim can see it — rewrap it with the mapping that caused it.
    throw new Error(`Envio Subgraph failed to load the mapping ${mappingFile}.\n  ${message}`);
  }
}

/**
 * `generated/` is usually gitignored, so it's built with the project's own
 * graph-cli — which makes the output identical to the user's normal workflow
 * by definition.
 */
function ensureGeneratedCode(root: string, { required }: { required: boolean }) {
  if (existsSync(path.join(root, "generated"))) return;

  const graphCli = path.join(root, "node_modules", ".bin", "graph");
  if (!existsSync(graphCli)) {
    if (!required) return;
    throw new Error(
      'Envio Subgraph needs the project\'s generated code, but "generated/" is\n' +
        "missing and @graphprotocol/graph-cli isn't installed.\n" +
        "Install dependencies and try again:\n" +
        "  pnpm install\n" +
        "Or generate manually:\n" +
        "  pnpm exec graph codegen",
    );
  }

  try {
    execFileSync(graphCli, ["codegen"], { cwd: root, stdio: "inherit" });
  } catch {
    throw new Error(
      'Envio Subgraph ran `graph codegen` to build "generated/", but it failed —\n' +
        "the error above comes from The Graph's own codegen, so fix it there and\n" +
        "rerun. If `graph codegen` succeeds on its own but fails through envio,\n" +
        "please open an issue: https://github.com/enviodev/hyperindex/issues",
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
function typeCheckMappings(root: string) {
  const graphCli = path.join(root, "node_modules", ".bin", "graph");
  if (!existsSync(graphCli)) return;

  const inputs = ["subgraph.yaml", "schema.graphql", "src", "abis"]
    .map((entry) => path.join(root, entry))
    .filter((entry) => existsSync(entry))
    .map((entry) => fingerprint(entry))
    .join("|");

  const stamp = path.join(root, ".envio", "graph-build.stamp");
  if (existsSync(stamp) && readFileSync(stamp, "utf8") === inputs) return;

  try {
    execFileSync(graphCli, ["build"], { cwd: root, stdio: "inherit" });
  } catch {
    throw new Error(
      "Envio Subgraph ran `graph build` to type-check the mappings, and it\n" +
        "failed — the error above comes from The Graph's own AssemblyScript\n" +
        "compiler, so fix it there and rerun.",
    );
  }

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

async function runRegisterHost(effect: Effect, input: unknown): Promise<unknown> {
  return effect.handler({
    input,
    // Only `blockTimestamp` reads the context, and only for the chain id, which
    // the input already carries for every other host op.
    context: { chain: { id: 0 } },
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
  const key = `${effect.name} ${typeof input === "string" ? input : JSON.stringify(input)}`;
  const resolved = scope.resolved ?? new Map();
  scope.resolved = resolved;

  const hit = resolved.get(key) ?? registerCache.get(key);
  if (hit) {
    if ("error" in hit) throw new RegisterHostFailure(effect.name, hit.error);
    return hit.value;
  }

  const awaiting = scope.awaiting ?? [];
  scope.awaiting = awaiting;
  awaiting.push(
    runRegisterHost(effect, input).then(
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
    let suspended = false;
    try {
      runInScope(scope, fn);
    } catch (error) {
      if (error !== REGISTER_SUSPEND) {
        // A host op that failed is never forgiven: the mapping was about to
        // decide what to create from its answer, and the handler pass cannot
        // repair a missed registration — addresses are registered at fetch
        // time. Fail the batch and let the retry get a real answer.
        if (error instanceof RegisterHostFailure) throw error;
        // This pass exists to collect `dataSource.create()` calls, and it runs
        // against a context that reads null for everything — so a handler that
        // assumes its entities exist throws here even though it is perfectly
        // correct. Nothing was registered, so there is nothing this pass could
        // have been for; the same mapping runs again with a real store, and any
        // error that is genuinely the mapping's surfaces there.
        if (scope.registered.size === 0) return;
        throw error;
      }
      suspended = true;
    }
    const awaiting = scope.awaiting;
    if (!suspended) return;
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
  resetClients();

  // One effect for every contract call: envio already batches and dedupes
  // effect calls in preload, and the block number in the input is what keeps
  // a cached result tied to the state the mapping saw.
  const rpcUrls = config.rpcUrls ?? [];
  const callEffect = makeCallEffect(rpcUrls);
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
  ensureGeneratedCode(config.root, { required: false });

  if (config.isDev) {
    typeCheckMappings(config.root);
  }

  const sources = [...config.dataSources, ...config.templates];
  const templateNames = new Set(config.templates.map((template) => template.name));

  for (const source of sources) {
    if (source.kind !== "contract") continue;
    const mapping = await loadMapping(config.root, source.mappingFile, {
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
      const EventClass = mapping[EVENT_CLASSES_EXPORT]?.[handler.handler] ?? ethereum.Event;
      const makeEvent = (event: unknown) => Reflect.construct(ethereum.Event, [event, kind], EventClass);

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
        mappingExports: mapping,
      });

      indexer.onEvent(
        { contract: config.contractAccessors[source.name], event: handler.name },
        async ({ event, context }: any) => {
          if (skipPreload && context.isPreload) return;
          const graphEvent = makeEvent(event);
          await (context as any).runSync(() =>
            runInScope(makeScope(event, context, "handler"), () => fn(graphEvent)),
          );
        },
      );

      // `dataSource.create` has to reach envio's contractRegister, which runs
      // at fetch time — before any entity exists. The same mapping reruns in
      // register mode, where writes and logs are no-ops and reads are null.
      if (templateNames.size > 0) {
        indexer.contractRegister(
          { contract: config.contractAccessors[source.name], event: handler.name },
          async ({ event, context }: any) => {
            const graphEvent = makeEvent(event);
            await runRegisterRounds(makeScope(event, context, "register"), () => fn(graphEvent));
          },
        );
      }
    }

    for (const handler of source.blockHandlers) {
      const fn = mapping[handler.handler];
      if (typeof fn !== "function") continue;
      const interval = blockInterval(handler);
      indexer.onBlock(
        {
          chain: source.chainId,
          name: `${source.name}_${handler.handler}`,
          interval: interval.once ? undefined : interval.every,
          ...(interval.once
            ? { block: { _gte: source.startBlock ?? 0, _lte: source.startBlock ?? 0 } }
            : {}),
        } as any,
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
