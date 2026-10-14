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
  entityFieldTypes: Record<
    string,
    Record<string, { kind: string; target?: string; derivedFrom?: string; list: boolean }>
  >;
  /** The context accessor envio generated for each entity, by schema name. */
  entityAccessors: Record<string, string>;
};

/** One event's register pass while it runs. */
export type RegisterPass = {
  position: number;
  done: Promise<void>;
  settled: boolean;
  /** The register-store keys it missed, so later passes can wait on it. */
  missed: string[];
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
  /** Where the event sits in its chain, for what the register pass may read. */
  position?: number;
  /** The register round's own writes, kept only once the round completes. */
  writes?: Map<string, Record<string, unknown> | null>;
  /** This register pass, as other passes of its batch wait on it. */
  pass?: RegisterPass;
  /** Entities this pass already waited on another pass for: it waits once. */
  waitedKeys?: Set<string>;
  /** The mapping module, so `ipfs.map` can reach the callback it names. */
  mappingExports: Record<string, any>;
  /** Set when the scope is a file data source's handler. */
  file?: FileScope;
  /** File templates this run created, keyed to dedupe a replayed mapping. */
  fileCreates?: Map<string, FileCreate>;
};

/** A `DataSourceTemplate.create` of a file template, waiting for its file. */
export type FileCreate = {
  template: string;
  /** The CID or Arweave transaction id the mapping passed. */
  source: string;
  /** The `DataSourceContext` of `createWithContext`, if there was one. */
  context?: unknown;
};

/** What distinguishes a file data source's handler run from a chain one. */
export type FileScope = {
  kind: "ipfs" | "arweave";
  /**
   * The manifest's `entities` list. graph-node lets a file data source touch
   * only these types, and refuses any other, read or write.
   */
  entities: Set<string>;
  /**
   * What this run has written, by entity type and id. graph-node keys an entity
   * by its causality region too, so a file data source can't see a chain
   * entity (or another file's) even of the same type and id: a read answers
   * from here only.
   */
  written: Set<string>;
  context?: unknown;
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
