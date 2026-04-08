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
import type { logger as Logger } from "./src/Envio.gen.ts";
import type { Address, EffectCaller } from "./src/Types.ts";
export type { EffectCaller, Address } from "./src/Types.ts";

export const TestHelpers: {
  Addresses: {
    readonly mockAddresses: readonly [
      Address, Address, Address, Address, Address,
      Address, Address, Address, Address, Address,
      Address, Address, Address, Address, Address,
      Address, Address, Address, Address, Address,
    ];
    readonly defaultAddress: Address;
  };
};

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
  /** Matches entities where the field is greater than or equal to the given value. */
  readonly _gte?: T;
  /** Matches entities where the field is less than or equal to the given value. */
  readonly _lte?: T;
  /** Matches entities where the field equals any of the given values. */
  readonly _in?: readonly T[];
};

/**
 * Filter on block number for `indexer.onBlock` `where` predicate. Reuses
 * `_gte`/`_lte` from {@link WhereOperator} and adds a block-specific `_every`.
 */
export type OnBlockNumberFilter = Pick<WhereOperator<number>, "_gte" | "_lte"> & {
  /**
   * Match every Nth block. Alignment is relative to `_gte` (or the chain's
   * configured startBlock when `_gte` is omitted), preserving the semantic
   * `(blockNumber - startBlock) % _every === 0`.
   */
  readonly _every?: number;
};

/** Structured filter object returned by an `indexer.onBlock` `where` predicate. */
export type OnBlockFilter = {
  readonly block?: {
    readonly number?: OnBlockNumberFilter;
  };
};

/**
 * Return type of an `indexer.onBlock` `where` predicate.
 * - `false` → skip this chain entirely.
 * - `true` / `undefined` → register on the chain with no extra filter.
 * - {@link OnBlockFilter} → register with the given range/stride.
 */
export type OnBlockWhereResult = boolean | OnBlockFilter | void;

/**
 * Constructs a getWhere filter type from an entity type.
 * Each field can be filtered using {@link WhereOperator} (`_eq`, `_gt`, `_lt`, `_gte`, `_lte`, `_in`).
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
  /** Number of blocks behind the chain head to lag (default: 0). */
  readonly blockLag?: number;
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
  /** Number of blocks behind the chain head to lag (default: 0). */
  readonly blockLag?: number;
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
  /** Number of blocks behind the chain head to lag (default: 0). */
  readonly blockLag?: number;
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
    contracts?: Record<string, Record<string, { eventName: string }>>;
    eventFilters?: Record<string, Record<string, { readonly params: object }>>;
  };
  fuel?: {
    chains: Record<string, { id: number }>;
    contracts?: Record<string, Record<string, { eventName: string }>>;
    eventFilters?: Record<string, Record<string, { readonly params: object }>>;
  };
  svm?: { chains: Record<string, { id: number }> };
  entities?: Record<string, object>;
};

// ============== onEvent / contractRegister Types ==============

// Extract contracts type from config
type EvmContracts<Config extends IndexerConfigTypes> =
  Config["evm"] extends { contracts: infer C extends Record<string, Record<string, any>> }
    ? C : {};

type FuelContracts<Config extends IndexerConfigTypes> =
  Config["fuel"] extends { contracts: infer C extends Record<string, Record<string, any>> }
    ? C : {};

// Extract eventFilters type from config — a sibling lookup table that maps
// contract+event to the `where` filter shape `{ params: { ... } }`. Split
// out from `EvmContracts` so per-event entries stay focused on the event
// payload and keep the two lookup tables independently composable.
type EvmEventFilters<Config extends IndexerConfigTypes> =
  Config["evm"] extends { eventFilters: infer F extends Record<string, Record<string, any>> }
    ? F : {};

type FuelEventFilters<Config extends IndexerConfigTypes> =
  Config["fuel"] extends { eventFilters: infer F extends Record<string, Record<string, any>> }
    ? F : {};

// Extract contract names for contract registration
type EvmContractNames<Config extends IndexerConfigTypes> =
  Config["evm"] extends { contracts: Record<infer N, any> } ? N & string : never;

type FuelContractNames<Config extends IndexerConfigTypes> =
  Config["fuel"] extends { contracts: Record<infer N, any> } ? N & string : never;

/** Event identity for onEvent/contractRegister calls. */
type EventIdentity<
  Contracts extends Record<string, Record<string, any>>,
  C extends keyof Contracts = keyof Contracts,
  E extends keyof Contracts[C] & string = keyof Contracts[C] & string
> = {
  /** The contract name as defined in config.yaml. */
  readonly contract: C;
  /** The event name as defined in the contract ABI. */
  readonly event: E;
  /** Whether to process all events (wildcard mode). */
  readonly wildcard?: boolean;
};

/**
 * Shared shape for handler contexts across ecosystems — logger, effect
 * caller, preload flag, chain state, and the entity operations map derived
 * from the project schema.
 */
type BaseHandlerContext<Config extends IndexerConfigTypes, ChainId> = {
  /** Access the logger instance. */
  readonly log: Logger;
  /** Call an Effect with the given input. */
  readonly effect: EffectCaller;
  /** True when running in preload mode (parallel pre-run for cache population). */
  readonly isPreload: boolean;
  /** Chain state for the current event's chain. */
  readonly chain: {
    readonly id: ChainId;
    readonly isLive: boolean;
  };
} & {
  readonly [K in keyof ConfigEntities<Config>]: EntityOperations<ConfigEntities<Config>[K]>;
};

/** Context for onEvent handlers. Includes entity operations, logging, and chain info. */
export type EvmOnEventContext<Config extends IndexerConfigTypes> = Prettify<
  BaseHandlerContext<Config, EvmChainIds<Config>>
>;

/** Context for onEvent handlers in Fuel ecosystem. */
export type FuelOnEventContext<Config extends IndexerConfigTypes> = Prettify<
  BaseHandlerContext<Config, FuelChainIds<Config>>
>;

/** Context for `indexer.onBlock` handlers in SVM ecosystem. */
export type SvmOnBlockContext<Config extends IndexerConfigTypes> = Prettify<
  BaseHandlerContext<Config, SvmChainIds<Config>>
>;

/** Entity operations available in handler contexts. */
type EntityOperations<Entity> = {
  readonly get: (id: string) => Promise<Entity | undefined>;
  readonly getOrThrow: (id: string, message?: string) => Promise<Entity>;
  readonly getWhere: (filter: GetWhereFilter<Entity>) => Promise<Entity[]>;
  readonly getOrCreate: (entity: Entity) => Promise<Entity>;
  readonly set: (entity: Entity) => void;
  readonly deleteUnsafe: (id: string) => void;
};

/** Contract registration handle. */
type ContractRegistration = {
  /** Register a new contract address for dynamic indexing. */
  readonly add: (address: Address) => void;
};

/** Context for contractRegister handlers. Chain object includes contract registration methods.
 * `isLive` is intentionally absent: contract registration runs during historical sync,
 * so the "live" distinction isn't meaningful and the runtime does not expose it. */
export type EvmContractRegisterContext<Config extends IndexerConfigTypes> = Prettify<{
  readonly log: Logger;
  readonly chain: {
    readonly id: EvmChainIds<Config>;
  } & {
    readonly [K in EvmContractNames<Config>]: ContractRegistration;
  };
}>;

/** Context for contractRegister handlers in Fuel ecosystem. `isLive` is intentionally
 * absent — see EvmContractRegisterContext. */
export type FuelContractRegisterContext<Config extends IndexerConfigTypes> = Prettify<{
  readonly log: Logger;
  readonly chain: {
    readonly id: FuelChainIds<Config>;
  } & {
    readonly [K in FuelContractNames<Config>]: ContractRegistration;
  };
}>;

// ============== onEvent / contractRegister Named Types ==============

/** Constraint: any event must have literal contractName and eventName fields. */
type EventLike = { readonly contractName: string; readonly eventName: string };

/** Scalar value or array of values — used by event filter fields to accept either a
 * single topic or multiple alternatives (OR semantics). */
export type SingleOrMultiple<T> = T | readonly T[];

/** EVM event type resolved by contract and event name. Union of all events when no generics provided.
 * The mapped form distributes `K in C` so disjoint event sets across contracts survive — using
 * `EvmContracts<Config>[C][E]` directly would collapse to keys common to *all* contracts (often `never`). */
export type EvmOnEvent<
  Config extends IndexerConfigTypes,
  C extends keyof EvmContracts<Config> = keyof EvmContracts<Config>,
  E extends string = string
> = {
  [K in C]: EvmContracts<Config>[K][E & keyof EvmContracts<Config>[K]];
}[C];

/** Arguments passed to the dynamic `where` callback form: the current chain
 * and addresses in scope. Return an `OnEventWhereFilter` to apply a filter,
 * or `true` / `false` to keep / skip all events for that invocation. */
export type OnEventWhereArgs = {
  readonly chainId: number;
  readonly addresses: readonly Address[];
};

/** A single `where` filter condition. The `{params}` wrapper reserves room
 * for future filter dimensions (block, transaction, …) as sibling fields.
 * `params` accepts either a single AND-conjunction of indexed-parameter
 * narrowings, or an array of them (OR semantics). */
export type OnEventWhereFilter<Params> = {
  readonly params?: Params | readonly Params[];
};

/** The `where` option value of `indexer.onEvent` / `indexer.contractRegister`.
 *
 * TypeScript accepts either a static filter object or a dynamic callback.
 * The dynamic callback may return a boolean to keep (`true`) or skip (`false`)
 * all events on that invocation, or an `OnEventWhereFilter` for narrowing.
 *
 * The ReScript surface only exposes the callback form — multi-condition OR
 * semantics are always expressed via an array on `params`, not at the top
 * level of `where`. */
export type OnEventWhere<Params> =
  | OnEventWhereFilter<Params>
  | ((args: OnEventWhereArgs) => OnEventWhereFilter<Params> | boolean);

/** Options for registering an EVM onEvent handler. Contract and event literal names are derived from the Event type.
 * The conditional `Event extends EventLike` distributes over union members so that each member's
 * contractName/eventName pair is constrained together — preventing invalid cross-member pairings.
 * The `Params` generic carries the indexed-parameter shape (looked up via `EvmEventFilters[C][E]["params"]`
 * by callers) so the `where` option enforces the same per-event narrowing as the inline handler signature. */
export type EvmOnEventOptions<Event extends EventLike, Params = {}> = Event extends EventLike
  ? {
      readonly contract: Event["contractName"];
      readonly event: Event["eventName"];
      readonly wildcard?: boolean;
      readonly where?: OnEventWhere<Params>;
    }
  : never;

/** Handler function for an EVM onEvent registration. Context is provided as a separate generic so the project alias can bind it. */
export type EvmOnEventHandler<Event extends EventLike, Context> = (args: {
  event: Event;
  context: Context;
}) => Promise<void>;

/** Options for registering an EVM contractRegister handler. Same shape as EvmOnEventOptions. */
export type EvmContractRegisterOptions<Event extends EventLike, Params = {}> = EvmOnEventOptions<
  Event,
  Params
>;

/** Handler function for an EVM contractRegister registration. */
export type EvmContractRegisterHandler<Event extends EventLike, Context> = EvmOnEventHandler<Event, Context>;

/** Fuel event type resolved by contract and event name. Same distributive-mapped pattern as `EvmOnEvent`. */
export type FuelOnEvent<
  Config extends IndexerConfigTypes,
  C extends keyof FuelContracts<Config> = keyof FuelContracts<Config>,
  E extends string = string
> = {
  [K in C]: FuelContracts<Config>[K][E & keyof FuelContracts<Config>[K]];
}[C];

/** Options for registering a Fuel onEvent handler. */
export type FuelOnEventOptions<Event extends EventLike, Params = {}> = EvmOnEventOptions<
  Event,
  Params
>;

/** Handler function for a Fuel onEvent registration. */
export type FuelOnEventHandler<Event extends EventLike, Context> = EvmOnEventHandler<Event, Context>;

/** Options for registering a Fuel contractRegister handler. */
export type FuelContractRegisterOptions<Event extends EventLike, Params = {}> = EvmOnEventOptions<
  Event,
  Params
>;

/** Handler function for a Fuel contractRegister registration. */
export type FuelContractRegisterHandler<Event extends EventLike, Context> = EvmOnEventHandler<Event, Context>;

// ============== Indexer Handler Methods ==============

/**
 * Shared shape for `indexer.onBlock` across ecosystems. The `HandlerArgs`
 * parameter lets each ecosystem supply its own block-identifier field
 * (`block.number` on EVM/Fuel, `slot` on SVM) alongside the context.
 */
type OnBlockMethod<Chain, HandlerArgs> = (
  options: {
    readonly name: string;
    readonly where?: (args: { readonly chain: Chain }) => OnBlockWhereResult;
  },
  handler: (args: HandlerArgs) => Promise<void>,
) => void;

// onEvent/contractRegister methods for EVM ecosystem
// NOTE: options use inline { contract: C; event: E } shape for TypeScript inference.
// Using EvmOnEventOptions<Contracts[C][E]> would break inference since C/E can't be
// derived from indexed access types. The named EvmOnEventOptions type is for end-user
// reference; the inline shape here is structurally identical.
type EvmHandlerMethods<Config extends IndexerConfigTypes> =
  Config["evm"] extends { contracts: infer Contracts extends Record<string, Record<string, any>> }
    ? {
        /** Register an event handler. */
        readonly onEvent: <
          C extends keyof Contracts & string,
          E extends keyof Contracts[C] & string
        >(
          options: {
            readonly contract: C;
            readonly event: E;
            readonly wildcard?: boolean;
            readonly where?: OnEventWhere<
              EvmEventFilters<Config>[C] extends Record<string, any>
                ? EvmEventFilters<Config>[C][E & keyof EvmEventFilters<Config>[C]] extends { readonly params: infer P }
                  ? P
                  : {}
                : {}
            >;
          },
          handler: EvmOnEventHandler<Contracts[C][E], EvmOnEventContext<Config>>
        ) => void;
        /** Register a contract register handler for dynamic contract indexing. */
        readonly contractRegister: <
          C extends keyof Contracts & string,
          E extends keyof Contracts[C] & string
        >(
          options: {
            readonly contract: C;
            readonly event: E;
            readonly wildcard?: boolean;
            readonly where?: OnEventWhere<
              EvmEventFilters<Config>[C] extends Record<string, any>
                ? EvmEventFilters<Config>[C][E & keyof EvmEventFilters<Config>[C]] extends { readonly params: infer P }
                  ? P
                  : {}
                : {}
            >;
          },
          handler: EvmContractRegisterHandler<Contracts[C][E], EvmContractRegisterContext<Config>>
        ) => void;
        /**
         * Register a Block Handler. `where` is evaluated once per configured
         * chain at registration time; return `false` to skip a chain, `true` /
         * `undefined` to match every block, or a filter object describing a
         * block-number range and stride.
         */
        readonly onBlock: OnBlockMethod<
          EvmChain<EvmChainIds<Config>, EvmContractNames<Config>>,
          {
            readonly block: { readonly number: number };
            readonly context: EvmOnEventContext<Config>;
          }
        >;
      }
    : {};

// onEvent/contractRegister methods for Fuel ecosystem
type FuelHandlerMethods<Config extends IndexerConfigTypes> =
  Config["fuel"] extends { contracts: infer Contracts extends Record<string, Record<string, any>> }
    ? {
        readonly onEvent: <
          C extends keyof Contracts & string,
          E extends keyof Contracts[C] & string
        >(
          options: {
            readonly contract: C;
            readonly event: E;
            readonly wildcard?: boolean;
            readonly where?: OnEventWhere<
              FuelEventFilters<Config>[C] extends Record<string, any>
                ? FuelEventFilters<Config>[C][E & keyof FuelEventFilters<Config>[C]] extends { readonly params: infer P }
                  ? P
                  : {}
                : {}
            >;
          },
          handler: FuelOnEventHandler<Contracts[C][E], FuelOnEventContext<Config>>
        ) => void;
        readonly contractRegister: <
          C extends keyof Contracts & string,
          E extends keyof Contracts[C] & string
        >(
          options: {
            readonly contract: C;
            readonly event: E;
            readonly wildcard?: boolean;
            readonly where?: OnEventWhere<
              FuelEventFilters<Config>[C] extends Record<string, any>
                ? FuelEventFilters<Config>[C][E & keyof FuelEventFilters<Config>[C]] extends { readonly params: infer P }
                  ? P
                  : {}
                : {}
            >;
          },
          handler: FuelContractRegisterHandler<Contracts[C][E], FuelContractRegisterContext<Config>>
        ) => void;
        /** Register a Block Handler. See `EvmHandlerMethods.onBlock` for the `where` semantics. */
        readonly onBlock: OnBlockMethod<
          FuelChain<FuelChainIds<Config>, FuelContractNames<Config>>,
          {
            readonly block: { readonly height: number };
            readonly context: FuelOnEventContext<Config>;
          }
        >;
      }
    : {};

// Handler methods for SVM ecosystem. Only onBlock — SVM has no onEvent yet.
type SvmHandlerMethods<Config extends IndexerConfigTypes> =
  HasSvm<Config> extends true
    ? {
        /** Register a Block Handler. See `EvmHandlerMethods.onBlock` for the `where` semantics. */
        readonly onBlock: OnBlockMethod<
          SvmChain<SvmChainIds<Config>>,
          {
            readonly slot: number;
            readonly context: SvmOnBlockContext<Config>;
          }
        >;
      }
    : {};

// Single ecosystem handler methods (flattened)
type SingleEcosystemHandlerMethods<Config extends IndexerConfigTypes> =
  HasEvm<Config> extends true
    ? EvmHandlerMethods<Config>
    : HasFuel<Config> extends true
    ? FuelHandlerMethods<Config>
    : HasSvm<Config> extends true
    ? SvmHandlerMethods<Config>
    : {};

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

// Multi-ecosystem chains (namespaced by ecosystem). Each ecosystem branch
// also includes its handler registration methods (onEvent, contractRegister)
// so multi-ecosystem indexers expose `indexer.evm.onEvent` etc. — mirrors
// the runtime object built in `Main.res`.
type MultiEcosystemChains<Config extends IndexerConfigTypes> =
  (HasEvm<Config> extends true
    ? {
        /** EVM ecosystem configuration. */
        readonly evm: EvmEcosystem<Config> & EvmHandlerMethods<Config>;
      }
    : {}) &
    (HasFuel<Config> extends true
      ? {
          /** Fuel ecosystem configuration. */
          readonly fuel: FuelEcosystem<Config> & FuelHandlerMethods<Config>;
        }
      : {}) &
    (HasSvm<Config> extends true
      ? {
          /** SVM ecosystem configuration. */
          readonly svm: SvmEcosystem<Config> & SvmHandlerMethods<Config>;
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
    ? SingleEcosystemChains<Config> & SingleEcosystemHandlerMethods<Config>
    : MultiEcosystemChains<Config>)
>;

// ============== Test Indexer Types ==============

/** Simulate item type for EVM ecosystem. */
type EvmSimulateItem<Config extends IndexerConfigTypes> =
  Config["evm"] extends { contracts: infer Contracts extends Record<string, Record<string, any>> }
    ? {
        [C in keyof Contracts]: {
          [E in keyof Contracts[C]]: {
            /** The contract name as defined in config.yaml. */
            contract: C;
            /** The event name as defined in the contract ABI. */
            event: E;
            /** Override the source address. Defaults to the first contract address. */
            srcAddress?: Address;
            /** Override the log index. Auto-increments by default. */
            logIndex?: number;
            /** Override block fields. */
            block?: Partial<Contracts[C][E]["block"]>;
            /** Override transaction fields. */
            transaction?: Partial<Contracts[C][E]["transaction"]>;
            /** Event parameters. Keys match the event's parameter names. */
            params?: Partial<Contracts[C][E]["params"]>;
          };
        }[keyof Contracts[C]];
      }[keyof Contracts]
    : never;

/** Simulate item type for Fuel ecosystem. */
type FuelSimulateItem<Config extends IndexerConfigTypes> =
  Config["fuel"] extends { contracts: infer Contracts extends Record<string, Record<string, any>> }
    ? {
        [C in keyof Contracts]: {
          [E in keyof Contracts[C]]: {
            /** The contract name as defined in config.yaml. */
            contract: C;
            /** The event name as defined in the contract ABI. */
            event: E;
            /** Override the source address. Defaults to the first contract address. */
            srcAddress?: Address;
            /** Override the log index. Auto-increments by default. */
            logIndex?: number;
            /** Override block fields. */
            block?: Partial<Contracts[C][E]["block"]>;
            /** Override transaction fields. */
            transaction?: Partial<Contracts[C][E]["transaction"]>;
            /** Event parameters. Keys match the event's parameter names. */
            params: Contracts[C][E]["params"];
          };
        }[keyof Contracts[C]];
      }[keyof Contracts]
    : never;

/** Configuration for a single EVM chain in the test indexer. */
type EvmTestIndexerChainConfig<Config extends IndexerConfigTypes> = {
  /** The block number to start processing from. Defaults to config startBlock or progressBlock+1. */
  startBlock?: number;
  /** The block number to stop processing at. Defaults to max simulate block number when simulate is provided. */
  endBlock?: number;
  /** Simulate items to process instead of fetching from real sources. */
  simulate?: EvmSimulateItem<Config>[];
};

/** Configuration for a single Fuel chain in the test indexer. */
type FuelTestIndexerChainConfig<Config extends IndexerConfigTypes> = {
  /** The block number to start processing from. Defaults to config startBlock or progressBlock+1. */
  startBlock?: number;
  /** The block number to stop processing at. Defaults to max simulate block height when simulate is provided. */
  endBlock?: number;
  /** Simulate items to process instead of fetching from real sources. */
  simulate?: FuelSimulateItem<Config>[];
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
type TestIndexerEntityOperations<Entity> = {
  /** Get an entity by ID. Returns undefined if not found. */
  readonly get: (id: string) => Promise<Entity | undefined>;
  /** Get an entity by ID or throw if not found. */
  readonly getOrThrow: (id: string, message?: string) => Promise<Entity>;
  /** Get all entities. */
  readonly getAll: () => Promise<Entity[]>;
  /** Set (create or update) an entity. */
  readonly set: (entity: Entity) => void;
};

/** A single change representing entity modifications at a specific block. */
type EntityChange<Config extends IndexerConfigTypes> = {
  /** The block where the changes occurred. */
  readonly block: number;
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


// Helper to extract chain IDs per ecosystem
type EvmChainIds<Config extends IndexerConfigTypes> =
  Config["evm"] extends { chains: infer Chains }
    ? Chains extends Record<string, { id: number }>
      ? Chains[keyof Chains]["id"]
      : never
    : never;

type FuelChainIds<Config extends IndexerConfigTypes> =
  Config["fuel"] extends { chains: infer Chains }
    ? Chains extends Record<string, { id: number }>
      ? Chains[keyof Chains]["id"]
      : never
    : never;

type SvmChainIds<Config extends IndexerConfigTypes> =
  Config["svm"] extends { chains: infer Chains }
    ? Chains extends Record<string, { id: number }>
      ? Chains[keyof Chains]["id"]
      : never
    : never;

// Per-ecosystem chain config mappings
type EvmTestChains<Config extends IndexerConfigTypes> =
  HasEvm<Config> extends true
    ? { [K in EvmChainIds<Config>]?: EvmTestIndexerChainConfig<Config> }
    : {};

type FuelTestChains<Config extends IndexerConfigTypes> =
  HasFuel<Config> extends true
    ? { [K in FuelChainIds<Config>]?: FuelTestIndexerChainConfig<Config> }
    : {};

/** Process configuration for the test indexer, with chains keyed by chain ID. */
export type TestIndexerProcessConfig<Config extends IndexerConfigTypes> = {
  /** Chain configurations keyed by chain ID. Each chain specifies start and end blocks. */
  chains: Prettify<
    EvmTestChains<Config> &
    FuelTestChains<Config>
  >;
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
} & (EcosystemCount<Config> extends 1
  ? SingleEcosystemChains<Config>
  : MultiEcosystemChains<Config>) & {
  /** Entity operations for direct manipulation outside of handlers. */
  readonly [K in keyof ConfigEntities<Config>]: TestIndexerEntityOperations<
    ConfigEntities<Config>[K]
  >;
};
