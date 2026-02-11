export type {
  logger as Logger,
  effect as Effect,
  effectContext as EffectContext,
  effectArgs as EffectArgs,
  effectOptions as EffectOptions,
  rateLimitDuration as RateLimitDuration,
  rateLimit as RateLimit,
  blockEvent as BlockEvent,
  fuelBlockEvent as FuelBlockEvent,
  svmOnBlockArgs as SvmOnBlockArgs,
  onBlockArgs as OnBlockArgs,
  onBlockOptions as OnBlockOptions,
} from "./src/Envio.gen.ts";
import type { Address } from "./src/Types.ts";
export type { EffectCaller, Address } from "./src/Types.ts";

/** Utility type to expand/flatten complex types for better IDE display. */
export type Prettify<T> = { [K in keyof T]: T[K] } & {};

/**
 * Operator for filtering entity fields in getWhere queries.
 * Only fields with `@index` in the schema can be queried at runtime.
 */
export type WhereOperator<T> = {
  /** Matches entities where the field equals the given value. */
  readonly _eq?: T;
  /** Matches entities where the field is greater than the given value. */
  readonly _gt?: T;
  /** Matches entities where the field is less than the given value. */
  readonly _lt?: T;
};

/**
 * Constructs a getWhere filter type from an entity type.
 * Each field can be filtered using {@link WhereOperator} (`_eq`, `_gt`, `_lt`).
 *
 * Note: only fields with `@index` in the schema can be queried at runtime.
 * Attempting to filter on a non-indexed field will throw a descriptive error.
 */
export type GetWhereFilter<E> = {
  [K in keyof E]?: WhereOperator<E[K]>;
};

import type {
  effect as Effect,
  effectArgs as EffectArgs,
  rateLimit as RateLimit,
} from "./src/Envio.gen.ts";

import { schema as bigDecimalSchema } from "./src/bindings/BigDecimal.gen.ts";
import { schema as bigintSchema } from "./src/bindings/BigInt.gen.ts";
import * as Sury from "rescript-schema";

type UnknownToOutput<T> = T extends Sury.Schema<unknown>
  ? Sury.Output<T>
  : T extends (...args: any[]) => any
  ? T
  : T extends unknown[]
  ? { [K in keyof T]: UnknownToOutput<T[K]> }
  : T extends { [k in keyof T]: unknown }
  ? Flatten<
      {
        [k in keyof T as HasUndefined<UnknownToOutput<T[k]>> extends true
          ? k
          : never]?: UnknownToOutput<T[k]>;
      } & {
        [k in keyof T as HasUndefined<UnknownToOutput<T[k]>> extends true
          ? never
          : k]: UnknownToOutput<T[k]>;
      }
    >
  : T;

type HasUndefined<T> = [T] extends [undefined]
  ? true
  : undefined extends T
  ? true
  : false;

// Utility to flatten the type into a single object
type Flatten<T> = T extends object
  ? { [K in keyof T as T[K] extends never ? never : K]: T[K] }
  : T;

// All the type gymnastics with generics to be able to
// define schema without an additional `S.schema` call in TS:
// createEffect({
//   input: undefined,
// })
// Instead of:
// createEffect({
//   input: S.schema(undefined),
// })
// Or for objects:
// createEffect({
//   input: {
//     foo: S.string,
//   },
// })
// Instead of:
// createEffect({
//   input: S.schema({
//     foo: S.string,
//   }),
// })
// The behaviour is inspired by Sury code:
// https://github.com/DZakh/sury/blob/551f8ee32c1af95320936d00c086e5fb337f59fa/packages/sury/src/S.d.ts#L344C1-L355C50
export function createEffect<
  IS,
  OS,
  I = UnknownToOutput<IS>,
  O = UnknownToOutput<OS>,
  // A hack to enforce that the inferred return type
  // matches the output schema type
  R extends O = O
>(
  options: {
    /** The name of the effect. Used for logging and debugging. */
    readonly name: string;
    /** The input schema of the effect. */
    readonly input: IS;
    /** The output schema of the effect. */
    readonly output: OS;
    /** Rate limit for the effect. Set to false to disable or provide {calls: number, per: "second" | "minute"} to enable. */
    readonly rateLimit: RateLimit;
    /** Whether the effect should be cached. */
    readonly cache?: boolean;
  },
  handler: (args: EffectArgs<I>) => Promise<R>
): Effect<I, O>;

// Important! Should match the index.js file
export declare namespace S {
  export type Output<T> = Sury.Output<T>;
  export type Infer<T> = Sury.Output<T>;
  export type Input<T> = Sury.Input<T>;
  export type Schema<Output, Input = unknown> = Sury.Schema<Output, Input>;
  export const string: typeof Sury.string;
  export const address: Sury.Schema<Address, Address>;
  // export const evmChainId: Sury.Schema<EvmChainId, EvmChainId>;
  // export const fuelChainId: Sury.Schema<FuelChainId, FuelChainId>;
  // export const svmChainId: Sury.Schema<SvmChainId, SvmChainId>;
  export const jsonString: typeof Sury.jsonString;
  export const boolean: typeof Sury.boolean;
  export const int32: typeof Sury.int32;
  export const number: typeof Sury.number;
  export const bigint: typeof bigintSchema;
  export const never: typeof Sury.never;
  export const union: typeof Sury.union;
  export const object: typeof Sury.object;
  // Might change in a near future
  // export const custom: typeof Sury.custom;
  // Don't expose recursive for now, since it's too advanced
  // export const recursive: typeof Sury.recursive;
  export const transform: typeof Sury.transform;
  export const shape: typeof Sury.shape;
  export const refine: typeof Sury.refine;
  export const schema: typeof Sury.schema;
  export const record: typeof Sury.record;
  export const array: typeof Sury.array;
  export const tuple: typeof Sury.tuple;
  export const merge: typeof Sury.merge;
  export const optional: typeof Sury.optional;
  export const nullable: typeof Sury.nullable;
  export const bigDecimal: typeof bigDecimalSchema;
  export const unknown: typeof Sury.unknown;
  // Nullish type will change in "sury@10"
  // export const nullish: typeof Sury.nullish;
  export const assertOrThrow: typeof Sury.assertOrThrow;
  export const parseOrThrow: typeof Sury.parseOrThrow;
}

// ============== Indexer Config (Module Augmentation) ==============

/**
 * Configuration interface for the indexer.
 * This interface is augmented by generated/envio.d.ts with project-specific config using typeof config.
 *
 * @example
 * // In generated/envio.d.ts:
 * declare module "envio" {
 *   interface Global {
 *     config: typeof config;
 *   }
 * }
 */
export interface Global {}

/**
 * Shape of the indexer configuration.
 * Will be used internally for defineConfig.
 * Currently should match the internal.config.json structure.
 */
type IndexerConfig = {
  /** The indexer name. */
  name: string;
  /** The indexer description. */
  description?: string;
  /** Path to handlers directory for auto-loading (default: "src/handlers"). */
  handlers?: string;
  /** Multichain mode: ordered or unordered (default: "unordered"). */
  multichain?: "ordered" | "unordered";
  /** Target batch size for event processing (default: 5000). */
  fullBatchSize?: number;
  /** Whether to rollback on chain reorg (default: true). */
  rollbackOnReorg?: boolean;
  /** Whether to save full entity history (default: false). */
  saveFullHistory?: boolean;
  /** Whether raw events are enabled (default: false). */
  rawEvents?: boolean;
  /** EVM ecosystem configuration. */
  evm?: {
    /** Chain configurations keyed by chain name. */
    chains: Record<string, EvmChainConfig>;
    /** Contract configurations keyed by contract name. */
    contracts?: Record<string, EvmContractConfig>;
    /** Address format (default: "checksum"). */
    addressFormat?: "lowercase" | "checksum";
  };
  /** Fuel ecosystem configuration. */
  fuel?: {
    /** Chain configurations keyed by chain name. */
    chains: Record<string, FuelChainConfig>;
    /** Contract configurations keyed by contract name. */
    contracts?: Record<string, FuelContractConfig>;
  };
  /** SVM ecosystem configuration. */
  svm?: {
    /** Chain configurations keyed by chain name. */
    chains: Record<string, SvmChainConfig>;
  };
};

// ============== Contract Types ==============

/** EVM contract configuration. */
type EvmContractConfig = {
  /** The contract ABI. */
  readonly abi: unknown;
};

/** Fuel contract configuration. */
type FuelContractConfig = {
  /** The contract ABI. */
  readonly abi: unknown;
};

// ============== EVM Types ==============

/** EVM chain configuration (for IndexerConfig). */
type EvmChainConfig<Id extends number = number> = {
  /** The chain ID. */
  readonly id: Id;
  /** The block number indexing starts from. */
  readonly startBlock: number;
  /** The block number indexing stops at (if configured). */
  readonly endBlock?: number;
  /** Number of blocks to keep for reorg handling (default: 200). */
  readonly maxReorgDepth?: number;
};

/** EVM chain value (for runtime Indexer). */
type EvmChain<
  Id extends number = number,
  ContractName extends string = never
> = {
  /** The chain ID. */
  readonly id: Id;
  /** The chain name. */
  readonly name: string;
  /** The block number indexing starts from. */
  readonly startBlock: number;
  /** The block number indexing stops at (if configured). */
  readonly endBlock: number | undefined;
  /** Whether the chain has completed initial sync and is processing live events. */
  readonly isLive: boolean;
} & {
  readonly [K in ContractName]: EvmContract<K>;
};

/** EVM contract (for runtime Indexer). */
type EvmContract<Name extends string = string> = {
  /** The contract name. */
  readonly name: Name;
  /** The contract ABI. */
  readonly abi: readonly unknown[];
  /** The contract addresses. */
  readonly addresses: readonly Address[];
};

/** Fuel contract (for runtime Indexer). */
type FuelContract<Name extends string = string> = {
  /** The contract name. */
  readonly name: Name;
  /** The contract ABI. */
  readonly abi: unknown;
  /** The contract addresses. */
  readonly addresses: readonly Address[];
};

// ============== Fuel Types ==============

/** Fuel chain configuration (for IndexerConfig). */
type FuelChainConfig<Id extends number = number> = {
  /** The chain ID. */
  readonly id: Id;
  /** The block number indexing starts from. */
  readonly startBlock: number;
  /** The block number indexing stops at (if configured). */
  readonly endBlock?: number;
  /** Number of blocks to keep for reorg handling (default: 200). */
  readonly maxReorgDepth?: number;
};

/** Fuel chain value (for runtime Indexer). */
type FuelChain<
  Id extends number = number,
  ContractName extends string = never
> = {
  /** The chain ID. */
  readonly id: Id;
  /** The chain name. */
  readonly name: string;
  /** The block number indexing starts from. */
  readonly startBlock: number;
  /** The block number indexing stops at (if configured). */
  readonly endBlock: number | undefined;
  /** Whether the chain has completed initial sync and is processing live events. */
  readonly isLive: boolean;
} & {
  readonly [K in ContractName]: FuelContract<K>;
};

// ============== SVM (Solana) Types ==============

/** SVM chain configuration (for IndexerConfig). */
type SvmChainConfig<Id extends number = number> = {
  /** The chain ID. */
  readonly id: Id;
  /** The block number indexing starts from. */
  readonly startBlock: number;
  /** The block number indexing stops at (if configured). */
  readonly endBlock?: number;
  /** Number of blocks to keep for reorg handling (default: 200). */
  readonly maxReorgDepth?: number;
};

/** SVM chain value (for runtime Indexer). */
type SvmChain<Id extends number = number> = {
  /** The chain ID. */
  readonly id: Id;
  /** The chain name. */
  readonly name: string;
  /** The block number indexing starts from. */
  readonly startBlock: number;
  /** The block number indexing stops at (if configured). */
  readonly endBlock: number | undefined;
  /** Whether the chain has completed initial sync and is processing live events. */
  readonly isLive: boolean;
};

// ============== Indexer Type ==============

/** Minimal type constraint for IndexerFromConfig to allow usage without full IndexerConfig. */
type IndexerConfigTypes = {
  evm?: {
    chains: Record<string, { id: number }>;
    contracts?: Record<string, {}>;
  };
  fuel?: {
    chains: Record<string, { id: number }>;
    contracts?: Record<string, {}>;
  };
  svm?: { chains: Record<string, { id: number }> };
  entities?: Record<string, object>;
};

// Helper: Check if ecosystem is configured in a given config
type HasEvm<Config> = "evm" extends keyof Config ? true : false;
type HasFuel<Config> = "fuel" extends keyof Config ? true : false;
type HasSvm<Config> = "svm" extends keyof Config ? true : false;

// Count ecosystems using tuple length
type BoolToNum<B extends boolean> = B extends true ? 1 : 0;
type EcosystemTuple<Config> = [
  ...([BoolToNum<HasEvm<Config>>] extends [1] ? [1] : []),
  ...([BoolToNum<HasFuel<Config>>] extends [1] ? [1] : []),
  ...([BoolToNum<HasSvm<Config>>] extends [1] ? [1] : [])
];
type EcosystemCount<Config> = EcosystemTuple<Config>["length"];

// EVM ecosystem type
type EvmEcosystem<Config extends IndexerConfigTypes> =
  "evm" extends keyof Config
    ? Config["evm"] extends {
        chains: infer Chains;
        contracts?: Record<infer ContractName, any>;
      }
      ? Chains extends Record<string, { id: number }>
        ? {
            /** Array of all EVM chain IDs. */
            readonly chainIds: readonly Chains[keyof Chains]["id"][];
            /** Per-chain configuration keyed by chain name or ID. */
            readonly chains: {
              readonly [K in Chains[keyof Chains]["id"]]: EvmChain<
                K,
                ContractName extends string ? ContractName : never
              >;
            } & {
              readonly [K in keyof Chains]: EvmChain<
                Chains[K]["id"],
                ContractName extends string ? ContractName : never
              >;
            };
          }
        : never
      : never
    : never;

// Fuel ecosystem type
type FuelEcosystem<Config extends IndexerConfigTypes> =
  "fuel" extends keyof Config
    ? Config["fuel"] extends {
        chains: infer Chains;
        contracts?: Record<infer ContractName, any>;
      }
      ? Chains extends Record<string, { id: number }>
        ? {
            /** Array of all Fuel chain IDs. */
            readonly chainIds: readonly Chains[keyof Chains]["id"][];
            /** Per-chain configuration keyed by chain name or ID. */
            readonly chains: {
              readonly [K in Chains[keyof Chains]["id"]]: FuelChain<
                K,
                ContractName extends string ? ContractName : never
              >;
            } & {
              readonly [K in keyof Chains]: FuelChain<
                Chains[K]["id"],
                ContractName extends string ? ContractName : never
              >;
            };
          }
        : never
      : never
    : never;

// SVM ecosystem type
type SvmEcosystem<Config extends IndexerConfigTypes> =
  "svm" extends keyof Config
    ? Config["svm"] extends { chains: infer Chains }
      ? Chains extends Record<string, { id: number }>
        ? {
            /** Array of all SVM chain IDs. */
            readonly chainIds: readonly Chains[keyof Chains]["id"][];
            /** Per-chain configuration keyed by chain name or ID. */
            readonly chains: {
              readonly [K in Chains[keyof Chains]["id"]]: SvmChain<K>;
            } & {
              readonly [K in keyof Chains]: SvmChain<Chains[K]["id"]>;
            };
          }
        : never
      : never
    : never;

// Single ecosystem chains (flattened at root level)
type SingleEcosystemChains<Config extends IndexerConfigTypes> =
  HasEvm<Config> extends true
    ? EvmEcosystem<Config>
    : HasFuel<Config> extends true
    ? FuelEcosystem<Config>
    : HasSvm<Config> extends true
    ? SvmEcosystem<Config>
    : {};

// Multi-ecosystem chains (namespaced by ecosystem)
type MultiEcosystemChains<Config extends IndexerConfigTypes> =
  (HasEvm<Config> extends true
    ? {
        /** EVM ecosystem configuration. */
        readonly evm: EvmEcosystem<Config>;
      }
    : {}) &
    (HasFuel<Config> extends true
      ? {
          /** Fuel ecosystem configuration. */
          readonly fuel: FuelEcosystem<Config>;
        }
      : {}) &
    (HasSvm<Config> extends true
      ? {
          /** SVM ecosystem configuration. */
          readonly svm: SvmEcosystem<Config>;
        }
      : {});

/**
 * Indexer type resolved from config, adapting chain properties based on configured ecosystems.
 * - Single ecosystem: chains are at the root level.
 * - Multiple ecosystems: chains are namespaced by ecosystem (evm, fuel, svm).
 */
export type IndexerFromConfig<Config extends IndexerConfigTypes> = Prettify<
  {
    /** The indexer name from config.yaml. */
    readonly name: string;
    /** The indexer description from config.yaml. */
    readonly description: string | undefined;
  } & (EcosystemCount<Config> extends 1
    ? SingleEcosystemChains<Config>
    : MultiEcosystemChains<Config>)
>;

// ============== Test Indexer Types ==============

/** Configuration for a single chain in the test indexer. */
export type TestIndexerChainConfig = {
  /** The block number to start processing from. */
  startBlock: number;
  /** The block number to stop processing at. */
  endBlock: number;
};

/** Entity change value containing sets and/or deleted IDs. */
type EntityChangeValue<Entity> = {
  /** Entities that were created or updated. */
  readonly sets?: readonly Entity[];
  /** IDs of entities that were deleted. */
  readonly deleted?: readonly string[];
};

/** A dynamic contract address registration. */
type AddressRegistration = {
  /** The contract address. */
  readonly address: Address;
  /** The contract name. */
  readonly contract: string;
};

/** Extract entities from config. */
type ConfigEntities<Config extends IndexerConfigTypes> =
  Config["entities"] extends Record<string, object> ? Config["entities"] : {};

/** Entity operations available on test indexer for direct entity manipulation. */
type EntityOps<Entity> = {
  /** Get an entity by ID. Returns undefined if not found. */
  readonly get: (id: string) => Promise<Entity | undefined>;
  /** Set (create or update) an entity. */
  readonly set: (entity: Entity) => void;
};

/** A single change representing entity modifications at a specific block. */
type EntityChange<Config extends IndexerConfigTypes> = {
  /** The block where the changes occurred. */
  readonly block: number;
  /** The block hash (if available). */
  readonly blockHash?: string;
  /** The chain ID. */
  readonly chainId: number;
  /** Number of events processed in this block. */
  readonly eventsProcessed: number;
  /** Dynamic contract address registrations for this block. */
  readonly addresses?: {
    readonly sets?: readonly AddressRegistration[];
  };
} & {
  readonly [K in keyof ConfigEntities<Config>]?: EntityChangeValue<
    ConfigEntities<Config>[K]
  >;
};


// Helper to extract chain IDs from config for test indexer
type TestIndexerChainIds<Config extends IndexerConfigTypes> =
  HasEvm<Config> extends true
    ? Config["evm"] extends { chains: infer Chains }
      ? Chains extends Record<string, { id: number }>
        ? Chains[keyof Chains]["id"]
        : never
      : never
    : HasFuel<Config> extends true
    ? Config["fuel"] extends { chains: infer Chains }
      ? Chains extends Record<string, { id: number }>
        ? Chains[keyof Chains]["id"]
        : never
      : never
    : HasSvm<Config> extends true
    ? Config["svm"] extends { chains: infer Chains }
      ? Chains extends Record<string, { id: number }>
        ? Chains[keyof Chains]["id"]
        : never
      : never
    : never;

/** Process configuration for the test indexer, with chains keyed by chain ID. */
export type TestIndexerProcessConfig<Config extends IndexerConfigTypes> = {
  /** Chain configurations keyed by chain ID. Each chain specifies start and end blocks. */
  chains: {
    [K in TestIndexerChainIds<Config>]?: TestIndexerChainConfig;
  };
};

/**
 * Test indexer type resolved from config.
 * Allows running the indexer for specific block ranges and inspecting results.
 */
export type TestIndexerFromConfig<Config extends IndexerConfigTypes> = {
  /** Process blocks for the specified chains and return progress with checkpoints and changes. */
  process: (
    config: Prettify<TestIndexerProcessConfig<Config>>
  ) => Promise<{
    /** Changes happened during the processing. */
    readonly changes: readonly EntityChange<Config>[];
  }>;
} & {
  /** Entity operations for direct manipulation outside of handlers. */
  readonly [K in keyof ConfigEntities<Config>]: EntityOps<
    ConfigEntities<Config>[K]
  >;
};
