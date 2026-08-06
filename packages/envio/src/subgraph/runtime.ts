/**
 * Turns a translated manifest into envio registrations.
 *
 * Each manifest handler becomes an `onEvent` / `onBlock` / `contractRegister`
 * wrapper that runs the mapping synchronously inside `runSync`: reads try the
 * in-memory state first, a miss schedules the async op and suspends, and the
 * replay loop reruns the mapping once what it asked for has landed.
 */

import { execFileSync } from "node:child_process";
import { existsSync } from "node:fs";
import { registerHooks } from "node:module";
import { pathToFileURL } from "node:url";
import path from "node:path";
import { indexer } from "../Api.res.mjs";
import { currentScope, runInScope, type Scope, type SubgraphSchema } from "./scope.ts";
import {
  Address,
  BigInt as GraphBigInt,
  Bytes,
  installCallHook,
  installHosts,
  installRegisterHook,
  ethereum,
  json as jsonNamespace,
  makeBlockHandlerBlock,
  valueToJs,
} from "./graph-ts.ts";
import { encodeArg, decodeArg, makeCallEffect, resetClients } from "./calls.ts";
import { makeHostEffects } from "./hosts.ts";
import { unsupported } from "./errors.ts";

const SHIM_URL = new URL("./graph-ts.ts", import.meta.url).href;

const jsonFromString = (line: string) => (jsonNamespace as any).fromString(line);

type EventHandler = { event: string; name: string; handler: string; receipt: boolean };
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
  isTemplate: boolean;
};
type SubgraphConfig = {
  specVersion: string;
  dataSources: DataSource[];
  templates: DataSource[];
  declaresEthCalls: boolean;
  root: string;
  rpcUrls: string[];
} & SubgraphSchema;

let hooksInstalled = false;

/**
 * Mappings resolve `@graphprotocol/graph-ts` to the shim; everything else,
 * including the project's own `generated/`, resolves normally and runs as-is.
 */
function installResolveHook() {
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
      return nextResolve(specifier, context);
    },
  });

  // AssemblyScript builtins the generated code uses as globals.
  const globals = globalThis as any;
  globals.changetype ??= (value: unknown) => value;
  globals.assert ??= (value: unknown, message?: string) => {
    if (!value) throw new Error(message ?? "assertion failed");
    return value;
  };
}

function blockInterval(handler: BlockHandler): { every?: number; once?: boolean } {
  const filter = handler.filter as any;
  if (filter === "Once" || filter?.Once !== undefined) return { once: true };
  if (typeof filter?.Every === "number") return { every: filter.Every };
  return { every: 1 };
}

/** The graph-ts `ethereum.Event` a mapping receives, over an envio event. */
function makeEvent(event: any, dataSourceName: string) {
  const params = Object.entries(event.params ?? {}).map(([name, value]) => ({
    name,
    value: toEthereumValue(value),
  }));


  const block = new (ethereum as any).Block(
    GraphBigInt.fromI32(event.block.number),
    () => GraphBigInt.fromI32(event.block.timestamp),
  );

  const wrapped: any = new (ethereum as any).Event(
    Address.fromString(event.srcAddress),
    GraphBigInt.fromI32(event.logIndex),
    undefined as never,
    block,
    event.transaction ?? {},
    params,
  );

  // Known-but-refused: envio has no per-transaction log index, and
  // `receipt.logs` can't be served from the selected receipt scalars.
  Object.defineProperty(wrapped, "transactionLogIndex", {
    get() {
      throw unsupported(
        "event.transactionLogIndex",
        `data source "${dataSourceName}" → a mapping handler`,
      );
    },
  });

  // Generated event classes read `event.parameters` positionally; a mapping
  // that skips codegen reads `event.params` by name. Both carry graph-ts
  // values, not envio's raw scalars.
  wrapped.parameters = params;
  wrapped.params = Object.fromEntries(
    Object.entries(event.params ?? {}).map(([name, value]) => [name, toGraphValue(value)]),
  );
  return wrapped;
}

/** envio's decoded event params -> the graph-ts values a mapping expects. */
function toGraphValue(value: unknown): unknown {
  if (typeof value === "bigint") return new (GraphBigInt as any)(value);
  if (Array.isArray(value)) return value.map(toGraphValue);
  if (typeof value === "string" && /^0x[0-9a-fA-F]{40}$/.test(value)) {
    return Address.fromString(value);
  }
  if (typeof value === "string" && /^0x[0-9a-fA-F]*$/.test(value)) {
    return Bytes.fromHexString(value);
  }
  return value;
}

function toEthereumValue(value: unknown): any {
  const V = (ethereum as any).Value;
  if (typeof value === "bigint") return V.fromBigInt(new (GraphBigInt as any)(value));
  if (typeof value === "string" && /^0x[0-9a-fA-F]*$/.test(value)) {
    return V.fromBytes(Bytes.fromHexString(value));
  }
  if (typeof value === "string") return V.fromString(value);
  if (typeof value === "boolean") return V.fromBoolean(value);
  if (typeof value === "number") return V.fromI32(value);
  return V.fromString(String(value));
}

async function loadMapping(root: string, mappingFile: string): Promise<Record<string, any>> {
  const url = pathToFileURL(path.resolve(root, mappingFile)).href;
  try {
    return await import(url);
  } catch (exn) {
    const message = exn instanceof Error ? exn.message : String(exn);
    // A mapping importing the project's `generated/` is the only thing that
    // makes codegen necessary, and this is exactly where that shows up.
    if (/Cannot find (module|package)/.test(message) && message.includes("generated")) {
      ensureGeneratedCode(root);
      return await import(url);
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
function ensureGeneratedCode(root: string) {
  if (existsSync(path.join(root, "generated"))) return;

  const graphCli = path.join(root, "node_modules", ".bin", "graph");
  if (!existsSync(graphCli)) {
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

export async function registerSubgraph(config: SubgraphConfig): Promise<void> {
  installResolveHook();
  resetClients();

  // One effect for every contract call: envio already batches and dedupes
  // effect calls in preload, and the block number in the input is what keeps
  // a cached result tied to the state the mapping saw.
  const rpcUrls = config.rpcUrls ?? [];
  const callEffect = makeCallEffect(rpcUrls);
  const hosts = makeHostEffects(rpcUrls);
  /**
   * The register pass has no effect caller: it runs at fetch time, against a
   * context that can only register addresses. An effect reached before any
   * `create()` could have decided which address to register, so it's refused;
   * once registration has happened, the rest of the mapping only feeds writes
   * that are no-ops here, so the call is skipped.
   */
  const callSync = (effect: unknown, input: unknown, what: string) => {
    const scope = currentScope();
    if (scope.mode === "register") {
      if (scope.registered.size === 0) {
        throw unsupported(
          `${what} before dataSource.create() in a handler that creates templates`,
          `data source "${scope.dataSource.name}" → a mapping handler`,
        );
      }
      return null;
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
  };

  const sources = [...config.dataSources, ...config.templates];
  const templateNames = new Set(config.templates.map((template) => template.name));

  for (const source of sources) {
    if (source.kind !== "contract") continue;
    const mapping = await loadMapping(config.root, source.mappingFile);

    for (const handler of source.eventHandlers) {
      const fn = mapping[handler.handler];
      if (typeof fn !== "function") {
        throw new Error(
          `Envio Subgraph can't find the handler "${handler.handler}" exported by ` +
            `${source.mappingFile} for data source "${source.name}".`,
        );
      }

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
        },
        registered: new Set(),
        blockNumber: event.block.number,
        mappingExports: mapping,
      });

      indexer.onEvent(
        { contract: source.name, event: handler.name },
        async ({ event, context }: any) => {
          const graphEvent = makeEvent(event, source.name);
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
          { contract: source.name, event: handler.name },
          ({ event, context }: any) => {
            const graphEvent = makeEvent(event, source.name);
            const scope = makeScope(event, context, "register");
            installRegisterHook((templateName, address) => {
              context.chain[templateName].add(address);
            });
            runInScope(scope, () => fn(graphEvent));
          },
        );
      }
    }

    for (const handler of source.blockHandlers) {
      const fn = mapping[handler.handler];
      if (typeof fn !== "function") {
        throw new Error(
          `Envio Subgraph can't find the block handler "${handler.handler}" exported by ` +
            `${source.mappingFile} for data source "${source.name}".`,
        );
      }
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
