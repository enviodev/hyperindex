import { AsyncLocalStorage } from "node:async_hooks";

/** What a wrapper is doing when it runs the mapping. */
export type Mode = "handler" | "register";

export type SubgraphSchema = {
  timestampFields: Record<string, string[]>;
  bytesIdEntities: string[];
  entityListFields: Record<string, string[]>;
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
  };
  /** Addresses already registered this round, so replays stay idempotent. */
  registered: Set<string>;
  /** The block a contract call is evaluated against, as graph-node does. */
  blockNumber: number;
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
