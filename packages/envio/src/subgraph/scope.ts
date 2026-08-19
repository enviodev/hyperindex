import { AsyncLocalStorage } from "node:async_hooks";

/** What a wrapper is doing when it runs the mapping. */
export type Mode = "handler" | "register";

export type SubgraphSchema = {
  timestampFields: Record<string, string[]>;
  bytesIdEntities: string[];
  entityListFields: Record<string, string[]>;
  entityFields: Record<string, string[]>;
  entityRefFields: Record<string, string[]>;
  /** Each field as the subgraph schema declares it, which is what a mapping reads. */
  entityFieldTypes: Record<string, Record<string, { kind: string; target?: string; list: boolean }>>;
};

export type Scope = {
  /** envio's handler or contractRegister context. */
  context: any;
  event: any;
  mode: Mode;
  schema: SubgraphSchema;
  dataSource: {
    name: string;
    address: string;
    chainId: number;
    network: string;
    /** The manifest's `context` entries, as `dataSource.context()` serves them. */
    context: Record<string, { type: string; data: string }>;
  };
  /** Addresses already registered this round, so replays stay idempotent. */
  registered: Set<string>;
  /**
   * Host results the register pass has resolved, keyed by effect and input.
   * The register pass has no envio context to run effects through, so it
   * replays the mapping itself and answers from here (§5, register mode).
   */
  resolved?: Map<string, { value?: unknown; error?: unknown }>;
  /** Lookups the current register round is waiting on. */
  awaiting?: Promise<unknown>[];
  /** The block a contract call is evaluated against, as graph-node does. */
  blockNumber: number;
  /** The mapping module, so `ipfs.map` can reach the callback it names. */
  mappingExports: Record<string, any>;
};

const storage = new AsyncLocalStorage<Scope>();

export function runInScope<T>(scope: Scope, fn: () => T): T {
  return storage.run(scope, fn);
}

export function currentScope(): Scope {
  const scope = storage.getStore();
  if (!scope) {
    throw new Error(
      "A graph-ts API was called outside of a mapping handler. Envio Subgraph " +
        "runs mappings inside a scope that carries the event and the store; " +
        "calling into graph-ts from module top-level or from a detached " +
        "callback escapes it.",
    );
  }
  return scope;
}
