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
import { pathToFileURL } from "node:url";
import path from "node:path";
import { indexer } from "../Api.res.mjs";
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
  json as jsonNamespace,
  makeBlockHandlerBlock,
  valueToJs,
} from "./graph-ts.ts";
import { encodeArg, decodeArg, makeCallEffect, resetClients } from "./calls.ts";
import {
  DIVIDE_HELPER,
  RETAG_HELPER,
  integerDivision,
  loadTypeScript,
  rewriteChangetype,
  rewriteDivision,
} from "./division.ts";
import { makeHostEffects } from "./hosts.ts";
import { unsupported } from "./errors.ts";

const SHIM_URL = new URL("./graph-ts.ts", import.meta.url).href;

const jsonFromString = (line: string) => (jsonNamespace as any).fromString(line);

type EventHandler = {
  event: string;
  name: string;
  handler: string;
  receipt: boolean;
  /** Each parameter's ABI type, keyed by the name envio decodes it under. */
  params?: Record<string, string>;
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
  root: string;
  rpcUrls: string[];
  isDev: boolean;
} & SubgraphSchema;

let hooksInstalled = false;
let projectRoot: string | null = null;

/**
 * Mappings resolve `@graphprotocol/graph-ts` to the shim; everything else,
 * including the project's own `generated/`, resolves normally and runs as-is.
 */
function installResolveHook(root: string) {
  projectRoot = pathToFileURL(path.resolve(root) + path.sep).href;
  // Loaded here rather than from inside the hook: requiring a module while a
  // load hook is on the stack re-enters the loader.
  loadTypeScript(path.resolve(root));
  if (hooksInstalled) return;
  hooksInstalled = true;

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
    load(url: string, context: any, nextLoad: any) {
      const loaded = nextLoad(url, context);
      if (!projectRoot || !url.startsWith(projectRoot) || url.includes("/node_modules/")) {
        return loaded;
      }
      const source = loaded?.source;
      if (typeof source !== "string" && !(source instanceof Uint8Array)) return loaded;
      const text = typeof source === "string" ? source : Buffer.from(source).toString("utf8");
      return { ...loaded, source: rewriteChangetype(rewriteDivision(text)) };
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

const ADDRESS_HEX = /^0x[0-9a-fA-F]{40}$/;
const ANY_HEX = /^0x[0-9a-fA-F]*$/;

type Converter = (value: unknown) => unknown;

/**
 * An ABI type as graph codegen types it. Anything that fits in 32 bits is an
 * `i32` in a mapping, and everything wider is a `BigInt` — which the value
 * alone can't tell you, since envio decodes every integer width as a bigint.
 */
const SMALL_INT = /^u?int(8|16|24|32)?$/;

function converterForAbiType(abiType: string): Converter {
  const type = abiType.trim();
  if (type.endsWith("]")) {
    const each = converterForAbiType(type.slice(0, type.lastIndexOf("[")));
    return (v) => (Array.isArray(v) ? v.map(each) : v);
  }
  if (type === "address") return (v) => Address.fromString(v as string);
  if (type === "bool") return (v) => v;
  if (type === "string") return (v) => v;
  if (type.startsWith("bytes")) return (v) => Bytes.fromHexString(v as string);
  // `int`/`uint` with no width are 256-bit.
  if (SMALL_INT.test(type) && type !== "int" && type !== "uint") {
    return (v) => (typeof v === "bigint" ? Number(v) : v);
  }
  if (/^u?int/.test(type)) return (v) => new (GraphBigInt as any)(v as bigint);
  return (v) => v;
}

/** Falls back to the value's own shape for a type the signature didn't carry. */
function converterForValue(value: unknown): Converter {
  if (typeof value === "bigint") return (v) => new (GraphBigInt as any)(v as bigint);
  if (typeof value === "string" && ADDRESS_HEX.test(value)) {
    return (v) => Address.fromString(v as string);
  }
  if (typeof value === "string" && ANY_HEX.test(value)) {
    return (v) => Bytes.fromHexString(v as string);
  }
  if (Array.isArray(value)) {
    const each = value.length > 0 ? converterForValue(value[0]) : (v: unknown) => v;
    return (v) => (v as unknown[]).map(each);
  }
  return (v) => v;
}

/**
 * An event's parameter types don't vary between occurrences, so the shape is
 * resolved once per event kind rather than per event.
 */
function convertersFor(
  cache: Map<string, Converter>,
  source: Record<string, unknown>,
  types: Map<string, string>,
) {
  for (const [name, value] of Object.entries(source)) {
    if (cache.has(name)) continue;
    const abiType = types.get(name);
    if (abiType) {
      cache.set(name, converterForAbiType(abiType));
      continue;
    }
    // A null carries no shape, and `to` is null on a contract creation. Caching
    // what it implies would pin the identity converter for every later event.
    if (value === null || value === undefined) continue;
    cache.set(name, converterForValue(value));
  }
  return cache;
}

function convertAll(
  cache: Map<string, Converter>,
  source: Record<string, unknown>,
  types: Map<string, string>,
) {
  const converters = convertersFor(cache, source, types);
  const out: Record<string, unknown> = {};
  for (const [name, value] of Object.entries(source)) {
    out[name] = (converters.get(name) ?? ((v: unknown) => v))(value);
  }
  return out;
}

/**
 * graph-ts' `ethereum.Block`, `Transaction` and `TransactionReceipt`, paired
 * with the name envio decodes each field under and the graph-ts type it has to
 * arrive as. The names diverge in both directions — graph-ts' `author` is
 * envio's `miner`, its `gasLimit` on a transaction is envio's `gas` — so a
 * mapping reading the graph-ts name gets `undefined` unless it's translated.
 */
type ShapeField = [graphName: string, rawName: string, kind: "bytes" | "address" | "bigint"];

const BLOCK_SHAPE: ShapeField[] = [
  ["hash", "hash", "bytes"],
  ["parentHash", "parentHash", "bytes"],
  ["unclesHash", "sha3Uncles", "bytes"],
  ["author", "miner", "address"],
  ["stateRoot", "stateRoot", "bytes"],
  ["transactionsRoot", "transactionsRoot", "bytes"],
  ["receiptsRoot", "receiptsRoot", "bytes"],
  ["number", "number", "bigint"],
  ["gasUsed", "gasUsed", "bigint"],
  ["gasLimit", "gasLimit", "bigint"],
  ["timestamp", "timestamp", "bigint"],
  ["difficulty", "difficulty", "bigint"],
  ["totalDifficulty", "totalDifficulty", "bigint"],
  ["size", "size", "bigint"],
  ["baseFeePerGas", "baseFeePerGas", "bigint"],
];

const TRANSACTION_SHAPE: ShapeField[] = [
  ["hash", "hash", "bytes"],
  ["index", "transactionIndex", "bigint"],
  ["from", "from", "address"],
  ["to", "to", "address"],
  ["value", "value", "bigint"],
  ["gasLimit", "gas", "bigint"],
  ["gasPrice", "gasPrice", "bigint"],
  ["input", "input", "bytes"],
  ["nonce", "nonce", "bigint"],
];

/** envio carries the receipt scalars on the transaction, not beside it. */
const RECEIPT_SHAPE: ShapeField[] = [
  ["transactionHash", "hash", "bytes"],
  ["transactionIndex", "transactionIndex", "bigint"],
  ["cumulativeGasUsed", "cumulativeGasUsed", "bigint"],
  ["gasUsed", "gasUsed", "bigint"],
  ["contractAddress", "contractAddress", "address"],
  ["status", "status", "bigint"],
  ["root", "root", "bytes"],
  ["logsBloom", "logsBloom", "bytes"],
];

function graphValue(kind: ShapeField[2], value: unknown): unknown {
  if (value === null || value === undefined) return null;
  if (kind === "bytes") return Bytes.fromHexString(value as string);
  if (kind === "address") return Address.fromString(value as string);
  return new (GraphBigInt as any)(typeof value === "bigint" ? value : BigInt(value as number));
}

function shaped(fields: ShapeField[], raw: Record<string, unknown> | undefined) {
  const out: Record<string, unknown> = {};
  for (const [graphName, rawName, kind] of fields) {
    out[graphName] = graphValue(kind, raw?.[rawName]);
  }
  return out;
}

/**
 * envio capitalizes a contract name for the config it stores, so a data source
 * whose manifest name starts lowercase — `crvUSD` — is `CrvUSD` by the time the
 * runtime looks it up. Register under the name the config actually holds.
 */
function contractName(name: string): string {
  return name.charAt(0).toUpperCase() + name.slice(1);
}

/**
 * The graph-ts `ethereum.Event` a mapping sees, built per event kind so the
 * refusals and conversions live on a prototype rather than being installed on
 * every event.
 *
 * Everything is deferred: a mapping that reads two parameters shouldn't pay to
 * convert the block, the transaction and the positional parameter list — and
 * envio runs each handler twice over the same payload, so anything eager is
 * paid twice.
 */
function makeEventClass(
  dataSourceName: string,
  eventName: string,
  declared: Map<string, string>,
  hasReceipt: boolean,
) {
  const paramConverters = new Map<string, Converter>();

  class SubgraphEvent {
    _raw: any;
    _address: any = undefined;
    _logIndex: any = undefined;
    _block: any = undefined;
    _transaction: any = undefined;
    _params: any = undefined;
    _parameters: any = undefined;
    _receipt: any = undefined;

    constructor(raw: any) {
      this._raw = raw;
    }

    get address() {
      return (this._address ??= Address.fromString(this._raw.srcAddress));
    }
    get logIndex() {
      return (this._logIndex ??= GraphBigInt.fromI32(this._raw.logIndex));
    }
    get block() {
      return (this._block ??= shaped(BLOCK_SHAPE, this._raw.block));
    }
    get transaction() {
      return (this._transaction ??= shaped(TRANSACTION_SHAPE, this._raw.transaction));
    }
    get receipt() {
      if (!hasReceipt) return null;
      return (this._receipt ??= Object.defineProperty(
        shaped(RECEIPT_SHAPE, this._raw.transaction),
        "logs",
        {
          get: () => {
            throw unsupported(
              "event.receipt.logs",
              `data source "${dataSourceName}" -> "${eventName}"`,
            );
          },
        },
      ));
    }
    /** Read by name, the way a hand-written mapping does. */
    get params() {
      return (this._params ??= convertAll(paramConverters, this._raw.params ?? {}, declared));
    }
    /**
     * Read positionally, the way `graph codegen`'s param classes do. Built off
     * the converted params so an array or a bytes value carries the type the
     * ABI declares rather than one guessed from its JS shape.
     */
    get parameters() {
      return (this._parameters ??= Object.entries(this.params).map(([name, value]) => ({
        name,
        value: toEthereumValue(value),
      })));
    }
    get transactionLogIndex(): never {
      throw unsupported(
        "event.transactionLogIndex",
        `data source "${dataSourceName}" → "${eventName}"`,
      );
    }
  }

  return SubgraphEvent;
}

function toEthereumValue(value: unknown): any {
  const V = (ethereum as any).Value;
  if (value === null || value === undefined) return V.fromNull();
  if (Array.isArray(value)) return V.fromArray(value.map(toEthereumValue));
  if (value instanceof Address || value instanceof Bytes) return V.fromBytes(value);
  if (value instanceof GraphBigInt) return V.fromBigInt(value);
  if (typeof value === "bigint") return V.fromBigInt(new (GraphBigInt as any)(value));
  if (typeof value === "boolean") return V.fromBoolean(value);
  if (typeof value === "number") return V.fromI32(value);
  if (typeof value === "string" && ANY_HEX.test(value)) {
    return V.fromBytes(Bytes.fromHexString(value));
  }
  return V.fromString(String(value));
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
    currentScope().context.chain[templateName].add(address);
  });

  installCallHook((call) => {
    const scope = currentScope();
    void scope;
    const encoded = JSON.stringify({
      chainId: currentScope().dataSource.chainId,
      address: call.contractAddress.toHexString(),
      signature: call.functionSignature,
      args: call.functionParams.map((param: any) => encodeArg(valueToJs(param))),
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

      // Parameter shapes are fixed per event kind, not per data source.
      const SubgraphEvent = makeEventClass(
        source.name,
        handler.name,
        new Map(Object.entries(handler.params ?? {})),
        handler.receipt ?? false,
      );

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
        { contract: contractName(source.name), event: handler.name },
        async ({ event, context }: any) => {
          const graphEvent = new SubgraphEvent(event);
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
          { contract: contractName(source.name), event: handler.name },
          async ({ event, context }: any) => {
            const graphEvent = new SubgraphEvent(event);
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
