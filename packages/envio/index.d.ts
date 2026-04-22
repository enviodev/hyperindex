import * as Sury from "rescript-schema";
import type { default as BigDecimalT } from "bignumber.js";

// Runtime value stubs used by the `S.*` namespace declarations further down
// so the exported `S.bigDecimal` / `S.bigint` consts pick up typed schemas.
// The implementations live in `index.js`, sourced from `.res.mjs` compiled
// output.
declare const bigDecimalSchema: Sury.Schema<BigDecimalT>;
declare const bigintSchema: Sury.Schema<bigint>;

/** Ethereum address — a 20-byte hex string prefixed with `0x`. */
export type Address = `0x${string}`;

/** Structured logger bound to an event or handler context. Messages are
 * displayed in the console and the Envio Hosted Service. */
export type Logger = {
  readonly debug: (
    message: string,
    params?: Record<string, unknown> | Error
  ) => void;
  readonly info: (
    message: string,
    params?: Record<string, unknown> | Error
  ) => void;
  readonly warn: (
    message: string,
    params?: Record<string, unknown> | Error
  ) => void;
  readonly error: (
    message: string,
    params?: Record<string, unknown> | Error
  ) => void;
};

/** Handle for an external-call effect created via {@link createEffect}.
 * Effects provide automatic deduplication, error handling, and caching. */
export declare abstract class Effect<I, O> {
  protected opaque: I | O;
}

/** Calls an {@link Effect} with the given input and returns its output. */
export type EffectCaller = <I, O>(
  effect: Effect<I, O>,
  // This is a hack to make the call complain on undefined
  // when it's not needed, instead of extending the input type.
  // Might be not needed if I misunderstand something in TS.
  input: I extends undefined ? undefined : I
) => Promise<O>;

/** Context passed to an Effect's handler function. */
export type EffectContext = {
  /** Access the logger instance with the event as context. */
  readonly log: Logger;
  /** Call another Effect from inside this one. */
  readonly effect: EffectCaller;
  /** Whether to cache this call's result. Defaults to the effect's `cache`
   * option; set to `false` to skip caching for this specific invocation. */
  cache: boolean;
};

/** Rate-limit window for an {@link Effect}. Strings resolve to common
 * durations; a plain `number` is treated as milliseconds. */
export type RateLimitDuration = "second" | "minute" | number;

/** Rate-limit configuration for an {@link Effect}. `false` disables rate
 * limiting; otherwise a `{calls, per}` pair caps invocations per duration. */
export type RateLimit =
  | false
  | { readonly calls: number; readonly per: RateLimitDuration };

/** Options accepted by {@link createEffect}. */
export type EffectOptions<Input, Output> = {
  /** The name of the effect. Used for logging and debugging. */
  readonly name: string;
  /** The input schema of the effect. */
  readonly input: Sury.Schema<Input>;
  /** The output schema of the effect. */
  readonly output: Sury.Schema<Output>;
  /** Rate limit for the effect. Set to `false` to disable or provide
   * `{calls, per: "second" | "minute"}` to enable. */
  readonly rateLimit: RateLimit;
  /** Whether the effect should be cached. */
  readonly cache?: boolean;
};

/** Arguments passed to the handler function of an {@link Effect}. */
export type EffectArgs<Input> = {
  readonly input: Input;
  readonly context: EffectContext;
};

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
 * Constructs a getWhere filter type from an entity type.
 * Each field can be filtered using {@link WhereOperator} (`_eq`, `_gt`, `_lt`, `_gte`, `_lte`, `_in`).
 *
 * Note: only fields with `@index` in the schema can be queried at runtime.
 * Attempting to filter on a non-indexed field will throw a descriptive error.
 */
export type GetWhereFilter<E> = {
  [K in keyof E]?: WhereOperator<E[K]>;
};

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
  export function nullable<Output, Input>(
    schema: Sury.Schema<Output, Input>
  ): Sury.Schema<Output | null, Input | null>;
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
 * Shape of the indexer configuration used internally for defineConfig.
 * This models only the subset of fields defineConfig consumes; the JSON
 * emitted by `envio config view` is a superset (enums, entities, per-chain
 * sources, event metadata, EVM global field selections, and other
 * serializer-only fields are intentionally omitted here).
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

/** Context for `indexer.onSlot` handlers in SVM ecosystem. */
export type SvmOnSlotContext<Config extends IndexerConfigTypes> = Prettify<
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

/** The chain object passed into the EVM dynamic `where` callback form. Exposes
 * the chain `id` and the event's own contract under its capitalized name,
 * with `addresses` listing the indexed contract addresses on this chain.
 *
 * Only the event's own contract is exposed — multi-contract address
 * filtering is not supported in this iteration. */
export type EvmOnEventWhereChain<ContractName extends string> = {
  readonly id: number;
} & {
  readonly [K in ContractName]: { readonly addresses: readonly Address[] };
};

/** Arguments passed to the EVM dynamic `where` callback form. Return an
 * `EvmOnEventWhereFilter` to apply a filter, or `true` / `false` to keep / skip
 * all events for that invocation. */
export type EvmOnEventWhereArgs<ContractName extends string> = {
  readonly chain: EvmOnEventWhereChain<ContractName>;
};

/** A single EVM `where` filter condition. `params` accepts either a single
 * AND-conjunction of indexed-parameter narrowings, or an array of them (OR
 * semantics). `block.number._gte` promotes to the event's startBlock and
 * overrides the contract-level `start_block` — use it to restrict per-event
 * processing without touching `config.yaml`. Only `_gte` is supported on
 * event filters; use `indexer.onBlock` for `_lte` / `_every`. */
export type EvmOnEventWhereFilter<Params> = {
  readonly params?: Params | readonly Params[];
  readonly block?: {
    readonly number?: {
      readonly _gte?: number;
    };
  };
};

/** The `where` option value of `indexer.onEvent` / `indexer.contractRegister`
 * in the EVM ecosystem.
 *
 * TypeScript accepts either a static filter object or a dynamic callback.
 * The dynamic callback may return a boolean to keep (`true`) or skip (`false`)
 * all events on that invocation, or an `EvmOnEventWhereFilter` for narrowing.
 *
 * The ReScript surface only exposes the callback form — multi-condition OR
 * semantics are always expressed via an array on `params`, not at the top
 * level of `where`. */
export type EvmOnEventWhere<Params, ContractName extends string> =
  | EvmOnEventWhereFilter<Params>
  | ((args: EvmOnEventWhereArgs<ContractName>) => EvmOnEventWhereFilter<Params> | boolean);

/** The chain object passed into the Fuel dynamic `where` callback form. */
export type FuelOnEventWhereChain<ContractName extends string> = EvmOnEventWhereChain<ContractName>;
/** Arguments passed to the Fuel dynamic `where` callback form. */
export type FuelOnEventWhereArgs<ContractName extends string> = EvmOnEventWhereArgs<ContractName>;
/** A single Fuel `where` filter condition. Keyed on `block.height` instead
 * of `block.number`. */
export type FuelOnEventWhereFilter<Params> = {
  readonly params?: Params | readonly Params[];
  readonly block?: {
    readonly height?: {
      readonly _gte?: number;
    };
  };
};
/** The `where` option value of `indexer.onEvent` / `indexer.contractRegister` in the Fuel ecosystem. */
export type FuelOnEventWhere<Params, ContractName extends string> =
  | FuelOnEventWhereFilter<Params>
  | ((args: FuelOnEventWhereArgs<ContractName>) => FuelOnEventWhereFilter<Params> | boolean);

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
      readonly where?: EvmOnEventWhere<Params, Event["contractName"] & string>;
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

// ============== EVM onBlock types ==============

/**
 * Structured filter object returned by an EVM `indexer.onBlock` `where`
 * predicate. `_every` alignment is relative to `_gte` (or the chain's
 * configured `startBlock` when `_gte` is omitted), preserving
 * `(blockNumber - startBlock) % _every === 0`.
 */
export type EvmOnBlockFilter = {
  readonly block?: {
    readonly number?: {
      /** Matches blocks whose number is greater than or equal to the given value. */
      readonly _gte?: number;
      /** Matches blocks whose number is less than or equal to the given value. */
      readonly _lte?: number;
      /** Match every Nth block. Alignment is relative to `_gte`. */
      readonly _every?: number;
    };
  };
};

/**
 * Return type of an EVM `indexer.onBlock` `where` predicate. The predicate
 * must explicitly return — an implicit `undefined` is not accepted.
 * - `false` → skip this chain entirely.
 * - `true` → register on the chain with no extra filter.
 * - {@link EvmOnBlockFilter} → register with the given range/stride.
 */
export type EvmOnBlockWhereResult = boolean | EvmOnBlockFilter;

/** Argument passed to an EVM `indexer.onBlock` `where` predicate. */
export type EvmOnBlockWhereArgs<Config extends IndexerConfigTypes> = {
  /** Configured chain being evaluated. Use `chain.id` to branch per chain. */
  readonly chain: EvmChain<EvmChainIds<Config>, EvmContractNames<Config>>;
};

/** Context for EVM `indexer.onBlock` handlers. Alias of {@link EvmOnEventContext}. */
export type EvmOnBlockContext<Config extends IndexerConfigTypes> = EvmOnEventContext<Config>;

/** Arguments passed to an EVM block handler. */
export type EvmOnBlockHandlerArgs<Config extends IndexerConfigTypes> = {
  /** Block being processed. Contains the block number; extended fields are
      opt-in via `field_selection` in config.yaml. */
  readonly block: { readonly number: number };
  /** Handler context: entity operations, logger, effect caller, chain state. */
  readonly context: EvmOnBlockContext<Config>;
};

/** Handler function for an EVM `indexer.onBlock` registration. */
export type EvmOnBlockHandler<Config extends IndexerConfigTypes> = (
  args: EvmOnBlockHandlerArgs<Config>,
) => Promise<void>;

/** Options for an EVM `indexer.onBlock` registration. */
export type EvmOnBlockOptions<Config extends IndexerConfigTypes> = {
  /** Unique name for this block handler. Used as the key in error messages
      and in persisted progress tracking. */
  readonly name: string;
  /** Optional predicate evaluated once per configured chain at registration
      time. Return `false` to skip a chain, `true` to match every block, or
      a filter object to restrict by block number range and stride. */
  readonly where?: (args: EvmOnBlockWhereArgs<Config>) => EvmOnBlockWhereResult;
};

// ============== Fuel onBlock types ==============

/**
 * Structured filter object returned by a Fuel `indexer.onBlock` `where`
 * predicate. `_every` alignment is relative to `_gte` (or the chain's
 * configured `startBlock` when `_gte` is omitted), preserving
 * `(blockNumber - startBlock) % _every === 0`.
 */
export type FuelOnBlockFilter = {
  readonly block?: {
    readonly height?: {
      /** Matches blocks whose height is greater than or equal to the given value. */
      readonly _gte?: number;
      /** Matches blocks whose height is less than or equal to the given value. */
      readonly _lte?: number;
      /** Match every Nth block. Alignment is relative to `_gte`. */
      readonly _every?: number;
    };
  };
};

/**
 * Return type of a Fuel `indexer.onBlock` `where` predicate. The predicate
 * must explicitly return — an implicit `undefined` is not accepted.
 * - `false` → skip this chain.
 * - `true` → register on the chain with no extra filter.
 * - {@link FuelOnBlockFilter} → register with the given range/stride.
 */
export type FuelOnBlockWhereResult = boolean | FuelOnBlockFilter;

/** Argument passed to a Fuel `indexer.onBlock` `where` predicate. */
export type FuelOnBlockWhereArgs<Config extends IndexerConfigTypes> = {
  /** Configured chain being evaluated. Use `chain.id` to branch per chain. */
  readonly chain: FuelChain<FuelChainIds<Config>, FuelContractNames<Config>>;
};

/** Context for Fuel `indexer.onBlock` handlers. Alias of {@link FuelOnEventContext}. */
export type FuelOnBlockContext<Config extends IndexerConfigTypes> = FuelOnEventContext<Config>;

/** Arguments passed to a Fuel block handler. */
export type FuelOnBlockHandlerArgs<Config extends IndexerConfigTypes> = {
  /** Block being processed. Contains the block height; extended fields are
      opt-in via `field_selection` in config.yaml. */
  readonly block: { readonly height: number };
  /** Handler context: entity operations, logger, effect caller, chain state. */
  readonly context: FuelOnBlockContext<Config>;
};

/** Handler function for a Fuel `indexer.onBlock` registration. */
export type FuelOnBlockHandler<Config extends IndexerConfigTypes> = (
  args: FuelOnBlockHandlerArgs<Config>,
) => Promise<void>;

/** Options for a Fuel `indexer.onBlock` registration. */
export type FuelOnBlockOptions<Config extends IndexerConfigTypes> = {
  /** Unique name for this block handler. Used as the key in error messages
      and in persisted progress tracking. */
  readonly name: string;
  /** Optional predicate evaluated once per configured chain at registration
      time. Return `false` to skip a chain, `true` to match every block, or
      a filter object to restrict by block height range and stride. */
  readonly where?: (args: FuelOnBlockWhereArgs<Config>) => FuelOnBlockWhereResult;
};

// ============== SVM onSlot types ==============

/**
 * Structured filter object returned by an SVM `indexer.onSlot` `where`
 * predicate. `_every` alignment is relative to `_gte` (or the chain's
 * configured `startBlock` when `_gte` is omitted), preserving
 * `(slot - startBlock) % _every === 0`.
 */
export type SvmOnSlotFilter = {
  readonly slot?: {
    /** Matches slots whose number is greater than or equal to the given value. */
    readonly _gte?: number;
    /** Matches slots whose number is less than or equal to the given value. */
    readonly _lte?: number;
    /** Match every Nth slot. Alignment is relative to `_gte`. */
    readonly _every?: number;
  };
};

/**
 * Return type of an SVM `indexer.onSlot` `where` predicate. The predicate
 * must explicitly return — an implicit `undefined` is not accepted.
 * - `false` → skip this chain.
 * - `true` → register on the chain with no extra filter.
 * - {@link SvmOnSlotFilter} → register with the given range/stride.
 */
export type SvmOnSlotWhereResult = boolean | SvmOnSlotFilter;

/** Argument passed to an SVM `indexer.onSlot` `where` predicate. */
export type SvmOnSlotWhereArgs<Config extends IndexerConfigTypes> = {
  /** Configured chain being evaluated. Use `chain.id` to branch per chain. */
  readonly chain: SvmChain<SvmChainIds<Config>>;
};

/** Arguments passed to an SVM slot handler. */
export type SvmOnSlotHandlerArgs<Config extends IndexerConfigTypes> = {
  /** Slot number being processed. */
  readonly slot: number;
  /** Handler context: entity operations, logger, effect caller, chain state. */
  readonly context: SvmOnSlotContext<Config>;
};

/** Handler function for an SVM `indexer.onSlot` registration. */
export type SvmOnSlotHandler<Config extends IndexerConfigTypes> = (
  args: SvmOnSlotHandlerArgs<Config>,
) => Promise<void>;

/** Options for an SVM `indexer.onSlot` registration. */
export type SvmOnSlotOptions<Config extends IndexerConfigTypes> = {
  /** Unique name for this slot handler. Used as the key in error messages
      and in persisted progress tracking. */
  readonly name: string;
  /** Optional predicate evaluated once per configured chain at registration
      time. Return `false` to skip a chain, `true` to match every slot, or
      a filter object to restrict by slot range and stride. */
  readonly where?: (args: SvmOnSlotWhereArgs<Config>) => SvmOnSlotWhereResult;
};

// ============== Indexer Types ==============

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

// EVM ecosystem type — includes chains plus handler registration methods.
// NOTE: options use inline { contract: C; event: E } shape for TypeScript inference.
// Using EvmOnEventOptions<Contracts[C][E]> would break inference since C/E can't be
// derived from indexed access types. The named EvmOnEventOptions type is for end-user
// reference; the inline shape here is structurally identical.
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
            /**
             * Register a block handler. `where` is evaluated once per configured
             * chain at registration time; return `false` to skip a chain, `true`
             * to match every block, or an {@link EvmOnBlockFilter} describing a
             * block-number range and stride. Always available regardless of
             * whether `contracts` are configured — block handlers don't need
             * any contract context.
             */
            readonly onBlock: (
              options: EvmOnBlockOptions<Config>,
              handler: EvmOnBlockHandler<Config>,
            ) => void;
          } & (Config["evm"] extends {
            contracts: infer Contracts extends Record<string, Record<string, any>>;
          }
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
                    readonly where?: EvmOnEventWhere<
                      EvmEventFilters<Config>[C] extends Record<string, any>
                        ? EvmEventFilters<Config>[C][E & keyof EvmEventFilters<Config>[C]] extends { readonly params: infer P }
                          ? P
                          : {}
                        : {},
                      C
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
                    readonly where?: EvmOnEventWhere<
                      EvmEventFilters<Config>[C] extends Record<string, any>
                        ? EvmEventFilters<Config>[C][E & keyof EvmEventFilters<Config>[C]] extends { readonly params: infer P }
                          ? P
                          : {}
                        : {},
                      C
                    >;
                  },
                  handler: EvmContractRegisterHandler<Contracts[C][E], EvmContractRegisterContext<Config>>
                ) => void;
              }
            : {})
        : never
      : never
    : never;

// Fuel ecosystem type — chains plus handler registration methods.
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
            /** Register a Fuel block handler. See `EvmEcosystem.onBlock` for
             * `where` semantics; Fuel filters on `block.height`. Always
             * available regardless of whether `contracts` are configured. */
            readonly onBlock: (
              options: FuelOnBlockOptions<Config>,
              handler: FuelOnBlockHandler<Config>,
            ) => void;
          } & (Config["fuel"] extends {
            contracts: infer Contracts extends Record<string, Record<string, any>>;
          }
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
                    readonly where?: FuelOnEventWhere<
                      FuelEventFilters<Config>[C] extends Record<string, any>
                        ? FuelEventFilters<Config>[C][E & keyof FuelEventFilters<Config>[C]] extends { readonly params: infer P }
                          ? P
                          : {}
                        : {},
                      C
                    >;
                  },
                  handler: FuelOnEventHandler<Contracts[C][E], FuelOnEventContext<Config>>
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
                    readonly where?: FuelOnEventWhere<
                      FuelEventFilters<Config>[C] extends Record<string, any>
                        ? FuelEventFilters<Config>[C][E & keyof FuelEventFilters<Config>[C]] extends { readonly params: infer P }
                          ? P
                          : {}
                        : {},
                      C
                    >;
                  },
                  handler: FuelContractRegisterHandler<Contracts[C][E], FuelContractRegisterContext<Config>>
                ) => void;
              }
            : {})
        : never
      : never
    : never;

// SVM ecosystem type — chains plus onSlot handler method. SVM has no onEvent yet.
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
            /**
             * Register a slot handler. `where` is evaluated once per configured
             * chain at registration time; return `false` to skip a chain, `true`
             * to match every slot, or an {@link SvmOnSlotFilter} describing a
             * slot range and stride.
             */
            readonly onSlot: (
              options: SvmOnSlotOptions<Config>,
              handler: SvmOnSlotHandler<Config>,
            ) => void;
          }
        : never
      : never
    : never;

// Single ecosystem chains (flattened at root level). Includes handler methods
// since, for single-ecosystem indexers, they live at root alongside `chains`.
type SingleEcosystemChains<Config extends IndexerConfigTypes> =
  HasEvm<Config> extends true
    ? EvmEcosystem<Config>
    : HasFuel<Config> extends true
    ? FuelEcosystem<Config>
    : HasSvm<Config> extends true
    ? SvmEcosystem<Config>
    : {};

// Multi-ecosystem chains (namespaced by ecosystem). Each ecosystem branch
// includes its handler registration methods — mirrors the runtime object
// built in `Main.res`.
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

/** Configuration for a single SVM chain in the test indexer. SVM has no
 * `onEvent` handlers yet, so simulate items aren't supported — only slot
 * range overrides for driving `indexer.onSlot` block handlers under test. */
type SvmTestIndexerChainConfig = {
  /** The slot number to start processing from. Defaults to config startBlock or progressBlock+1. */
  startBlock?: number;
  /** The slot number to stop processing at. */
  endBlock?: number;
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

type SvmTestChains<Config extends IndexerConfigTypes> =
  HasSvm<Config> extends true
    ? { [K in SvmChainIds<Config>]?: SvmTestIndexerChainConfig }
    : {};

/** Process configuration for the test indexer, with chains keyed by chain ID. */
export type TestIndexerProcessConfig<Config extends IndexerConfigTypes> = {
  /** Chain configurations keyed by chain ID. Each chain specifies start and end blocks. */
  chains: Prettify<
    EvmTestChains<Config> &
    FuelTestChains<Config> &
    SvmTestChains<Config>
  >;
};

// Per-ecosystem test-indexer ecosystem types — structurally the `chainIds +
// chains` slice of the real ecosystem types, but without the handler
// registration methods (the test indexer doesn't let you register new
// handlers, only run the existing ones over simulated or persisted data).
// Kept as a separate type family so the real and test surfaces can evolve
// independently without one silently lying about the other.
type EvmTestEcosystem<Config extends IndexerConfigTypes> =
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

type FuelTestEcosystem<Config extends IndexerConfigTypes> =
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

type SvmTestEcosystem<Config extends IndexerConfigTypes> =
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

// Test-side single/multi chain selectors, parallel to the real ones.
type SingleEcosystemTestChains<Config extends IndexerConfigTypes> =
  HasEvm<Config> extends true
    ? EvmTestEcosystem<Config>
    : HasFuel<Config> extends true
    ? FuelTestEcosystem<Config>
    : HasSvm<Config> extends true
    ? SvmTestEcosystem<Config>
    : {};

type MultiEcosystemTestChains<Config extends IndexerConfigTypes> =
  (HasEvm<Config> extends true
    ? {
        /** EVM ecosystem configuration. */
        readonly evm: EvmTestEcosystem<Config>;
      }
    : {}) &
    (HasFuel<Config> extends true
      ? {
          /** Fuel ecosystem configuration. */
          readonly fuel: FuelTestEcosystem<Config>;
        }
      : {}) &
    (HasSvm<Config> extends true
      ? {
          /** SVM ecosystem configuration. */
          readonly svm: SvmTestEcosystem<Config>;
        }
      : {});

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
  ? SingleEcosystemTestChains<Config>
  : MultiEcosystemTestChains<Config>) & {
  /** Entity operations for direct manipulation outside of handlers. */
  readonly [K in keyof ConfigEntities<Config>]: TestIndexerEntityOperations<
    ConfigEntities<Config>[K]
  >;
};

// ============== Runtime values ==============

// Runtime indexer object. The concrete shape is resolved per-project by the
// generated package's `index.d.ts`, which re-declares these values with
// `IndexerFromConfig<IndexerConfigTypes>` / `TestIndexerFromConfig<...>`
// bound to the project's chains, contracts, and entities. Imports from the
// `envio` package directly see the permissive `any` typing below.
export declare const indexer: any;
export declare const createTestIndexer: () => any;
