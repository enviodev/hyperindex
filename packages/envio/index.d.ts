import * as Sury from "rescript-schema";
import type { default as BigDecimalT } from "bignumber.js";
export { default as BigDecimal } from "bignumber.js";

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
 * Only `id` and fields with `@index` in the schema can be queried at runtime.
 */
export type GetWhereOperator<T> = {
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
 * Each field can be filtered using {@link GetWhereOperator} (`_eq`, `_gt`, `_lt`, `_gte`, `_lte`, `_in`).
 *
 * Note: only `id` and fields with `@index` in the schema can be queried at runtime.
 * Attempting to filter on a non-indexed field will throw a descriptive error.
 */
export type GetWhereFilter<E> = {
  [K in keyof E]?: GetWhereOperator<E[K]>;
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
 * Internal augmentation surface populated by `.envio/types.d.ts` (via
 * codegen) so the project-bound aliases below resolve to concrete chain /
 * contract / entity / enum types.
 *
 * Do not augment manually. If a project-bound type like {@link Indexer},
 * {@link Entities}, or {@link EvmChainName} resolves to an error string,
 * run `envio codegen` (or your package manager's `codegen` script, e.g.
 * `pnpm codegen`) to regenerate `.envio/types.d.ts`.
 */
export interface Global {}

/** Lookup table extracted from {@link Global} — empty when not yet augmented. */
type GlobalConfig = Global extends { config: infer C extends IndexerConfigTypes }
  ? C
  : {};

/** Error-message string returned by project-bound aliases when codegen has
 *  not run yet. Resolves to `string` so handler signatures stay assignable.
 *  Wording is package-manager-neutral — `envio init` lets users pick pnpm,
 *  npm, yarn, or bun, so the hint refers to the codegen invocation rather
 *  than a specific PM. */
type NotConfigured<TName extends string, THint extends string> =
  `${TName} is not available. ${THint} in config.yaml and run 'envio codegen'`;

type IsEmptyObject<T> = keyof T extends never ? true : false;

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
  /** Whether all chains have entered real-time indexing mode (caught up to head,
   * or reached their configured endBlock for finite-range indexers). */
  readonly isRealtime: boolean;
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
  /** Whether all chains have entered real-time indexing mode (caught up to head,
   * or reached their configured endBlock for finite-range indexers). */
  readonly isRealtime: boolean;
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
  /** Whether all chains have entered real-time indexing mode (caught up to head,
   * or reached their configured endBlock for finite-range indexers). */
  readonly isRealtime: boolean;
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
  enums?: Record<string, string>;
};

// ============== onEvent / contractRegister Types ==============

// Extract contracts type from config
type EvmContracts<Config extends IndexerConfigTypes = GlobalConfig> =
  Config["evm"] extends { contracts: infer C extends Record<string, Record<string, any>> }
    ? C : {};

type FuelContracts<Config extends IndexerConfigTypes = GlobalConfig> =
  Config["fuel"] extends { contracts: infer C extends Record<string, Record<string, any>> }
    ? C : {};

// Extract eventFilters type from config — a sibling lookup table that maps
// contract+event to the `where` filter shape `{ params: { ... } }`. Split
// out from `EvmContracts` so per-event entries stay focused on the event
// payload and keep the two lookup tables independently composable.
type EvmEventFilters<Config extends IndexerConfigTypes = GlobalConfig> =
  Config["evm"] extends { eventFilters: infer F extends Record<string, Record<string, any>> }
    ? F : {};

type FuelEventFilters<Config extends IndexerConfigTypes = GlobalConfig> =
  Config["fuel"] extends { eventFilters: infer F extends Record<string, Record<string, any>> }
    ? F : {};

// Extract contract names for contract registration
type EvmContractNames<Config extends IndexerConfigTypes = GlobalConfig> =
  Config["evm"] extends { contracts: Record<infer N, any> } ? N & string : never;

type FuelContractNames<Config extends IndexerConfigTypes = GlobalConfig> =
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
type BaseHandlerContext<Config extends IndexerConfigTypes = GlobalConfig, ChainId = unknown> = {
  /** Access the logger instance. */
  readonly log: Logger;
  /** Call an Effect with the given input. */
  readonly effect: EffectCaller;
  /** True when running in preload mode (parallel pre-run for cache population). */
  readonly isPreload: boolean;
  /** Chain state for the current event's chain. */
  readonly chain: {
    readonly id: ChainId;
    readonly isRealtime: boolean;
  };
} & {
  readonly [K in keyof ConfigEntities<Config>]: EntityOperations<ConfigEntities<Config>[K]>;
};

/** Context for onEvent handlers. Includes entity operations, logging, and chain info. */
export type EvmOnEventContext<Config extends IndexerConfigTypes = GlobalConfig> = Prettify<
  BaseHandlerContext<Config, EvmChainIds<Config>>
>;

/** Context for onEvent handlers in Fuel ecosystem. */
export type FuelOnEventContext<Config extends IndexerConfigTypes = GlobalConfig> = Prettify<
  BaseHandlerContext<Config, FuelChainIds<Config>>
>;

/** Context for `indexer.onSlot` handlers in SVM ecosystem. */
export type SvmOnSlotContext<Config extends IndexerConfigTypes = GlobalConfig> = Prettify<
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
 * `isRealtime` is intentionally absent: contract registration runs during historical sync,
 * so the "realtime" distinction isn't meaningful and the runtime does not expose it. */
export type EvmContractRegisterContext<Config extends IndexerConfigTypes = GlobalConfig> = Prettify<{
  readonly log: Logger;
  readonly chain: {
    readonly id: EvmChainIds<Config>;
  } & {
    readonly [K in EvmContractNames<Config>]: ContractRegistration;
  };
}>;

/** Context for contractRegister handlers in Fuel ecosystem. `isRealtime` is intentionally
 * absent — see EvmContractRegisterContext. */
export type FuelContractRegisterContext<Config extends IndexerConfigTypes = GlobalConfig> = Prettify<{
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
  Config extends IndexerConfigTypes = GlobalConfig,
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

// When the matching ecosystem isn't configured, `EvmEvent` / `FuelEvent` resolve
// to the error-message string. Filter back to a structural `EventLike` so the
// default-bound option / handler aliases stay usable in non-configured cases.
type _ProjectEvmEvent = EvmEvent extends EventLike ? EvmEvent : never;
type _ProjectFuelEvent = FuelEvent extends EventLike ? FuelEvent : never;

/** Options for registering an EVM onEvent handler. Contract and event literal names are derived from the Event type.
 * The conditional `Event extends EventLike` distributes over union members so that each member's
 * contractName/eventName pair is constrained together — preventing invalid cross-member pairings.
 * The `Params` generic carries the indexed-parameter shape (looked up via `EvmEventFilters[C][E]["params"]`
 * by callers) so the `where` option enforces the same per-event narrowing as the inline handler signature. */
export type EvmOnEventOptions<Event extends EventLike = _ProjectEvmEvent, Params = {}> = Event extends EventLike
  ? {
      readonly contract: Event["contractName"];
      readonly event: Event["eventName"];
      readonly wildcard?: boolean;
      readonly where?: EvmOnEventWhere<Params, Event["contractName"] & string>;
    }
  : never;

/** Handler function for an EVM onEvent registration. Context is provided as a separate generic so the project alias can bind it. */
export type EvmOnEventHandler<
  Event extends EventLike = _ProjectEvmEvent,
  Context = EvmOnEventContext,
> = (args: { event: Event; context: Context }) => Promise<void>;

/** Options for registering an EVM contractRegister handler. Same shape as EvmOnEventOptions. */
export type EvmContractRegisterOptions<
  Event extends EventLike = _ProjectEvmEvent,
  Params = {},
> = EvmOnEventOptions<Event, Params>;

/** Handler function for an EVM contractRegister registration. */
export type EvmContractRegisterHandler<
  Event extends EventLike = _ProjectEvmEvent,
  Context = EvmContractRegisterContext,
> = EvmOnEventHandler<Event, Context>;

/** Fuel event type resolved by contract and event name. Same distributive-mapped pattern as `EvmOnEvent`. */
export type FuelOnEvent<
  Config extends IndexerConfigTypes = GlobalConfig,
  C extends keyof FuelContracts<Config> = keyof FuelContracts<Config>,
  E extends string = string
> = {
  [K in C]: FuelContracts<Config>[K][E & keyof FuelContracts<Config>[K]];
}[C];

/** Options for registering a Fuel onEvent handler. Mirrors `EvmOnEventOptions`
 * but binds the `where` filter to `FuelOnEventWhere` so block ranges read
 * `block.height` (Fuel) instead of `block.number` (EVM). */
export type FuelOnEventOptions<
  Event extends EventLike = _ProjectFuelEvent,
  Params = {},
> = Event extends EventLike
  ? {
      readonly contract: Event["contractName"];
      readonly event: Event["eventName"];
      readonly wildcard?: boolean;
      readonly where?: FuelOnEventWhere<Params, Event["contractName"] & string>;
    }
  : never;

/** Handler function for a Fuel onEvent registration. */
export type FuelOnEventHandler<
  Event extends EventLike = _ProjectFuelEvent,
  Context = FuelOnEventContext,
> = EvmOnEventHandler<Event, Context>;

/** Options for registering a Fuel contractRegister handler. Same shape as
 * `FuelOnEventOptions` so the `where` filter uses `block.height`. */
export type FuelContractRegisterOptions<
  Event extends EventLike = _ProjectFuelEvent,
  Params = {},
> = FuelOnEventOptions<Event, Params>;

/** Handler function for a Fuel contractRegister registration. */
export type FuelContractRegisterHandler<
  Event extends EventLike = _ProjectFuelEvent,
  Context = FuelContractRegisterContext,
> = EvmOnEventHandler<Event, Context>;

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
export type EvmOnBlockWhereArgs<Config extends IndexerConfigTypes = GlobalConfig> = {
  /** Configured chain being evaluated. Use `chain.id` to branch per chain. */
  readonly chain: EvmChain<EvmChainIds<Config>, EvmContractNames<Config>>;
};

/** Context for EVM `indexer.onBlock` handlers. Alias of {@link EvmOnEventContext}. */
export type EvmOnBlockContext<Config extends IndexerConfigTypes = GlobalConfig> = EvmOnEventContext<Config>;

/** Arguments passed to an EVM block handler. */
export type EvmOnBlockHandlerArgs<Config extends IndexerConfigTypes = GlobalConfig> = {
  /** Block being processed. Contains the block number; extended fields are
      opt-in via `field_selection` in config.yaml. */
  readonly block: { readonly number: number };
  /** Handler context: entity operations, logger, effect caller, chain state. */
  readonly context: EvmOnBlockContext<Config>;
};

/** Handler function for an EVM `indexer.onBlock` registration. */
export type EvmOnBlockHandler<Config extends IndexerConfigTypes = GlobalConfig> = (
  args: EvmOnBlockHandlerArgs<Config>,
) => Promise<void>;

/** Options for an EVM `indexer.onBlock` registration. */
export type EvmOnBlockOptions<Config extends IndexerConfigTypes = GlobalConfig> = {
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
export type FuelOnBlockWhereArgs<Config extends IndexerConfigTypes = GlobalConfig> = {
  /** Configured chain being evaluated. Use `chain.id` to branch per chain. */
  readonly chain: FuelChain<FuelChainIds<Config>, FuelContractNames<Config>>;
};

/** Context for Fuel `indexer.onBlock` handlers. Alias of {@link FuelOnEventContext}. */
export type FuelOnBlockContext<Config extends IndexerConfigTypes = GlobalConfig> = FuelOnEventContext<Config>;

/** Arguments passed to a Fuel block handler. */
export type FuelOnBlockHandlerArgs<Config extends IndexerConfigTypes = GlobalConfig> = {
  /** Block being processed. Contains the block height; extended fields are
      opt-in via `field_selection` in config.yaml. */
  readonly block: { readonly height: number };
  /** Handler context: entity operations, logger, effect caller, chain state. */
  readonly context: FuelOnBlockContext<Config>;
};

/** Handler function for a Fuel `indexer.onBlock` registration. */
export type FuelOnBlockHandler<Config extends IndexerConfigTypes = GlobalConfig> = (
  args: FuelOnBlockHandlerArgs<Config>,
) => Promise<void>;

/** Options for a Fuel `indexer.onBlock` registration. */
export type FuelOnBlockOptions<Config extends IndexerConfigTypes = GlobalConfig> = {
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
export type SvmOnSlotWhereArgs<Config extends IndexerConfigTypes = GlobalConfig> = {
  /** Configured chain being evaluated. Use `chain.id` to branch per chain. */
  readonly chain: SvmChain<SvmChainIds<Config>>;
};

/** Arguments passed to an SVM slot handler. */
export type SvmOnSlotHandlerArgs<Config extends IndexerConfigTypes = GlobalConfig> = {
  /** Slot number being processed. */
  readonly slot: number;
  /** Handler context: entity operations, logger, effect caller, chain state. */
  readonly context: SvmOnSlotContext<Config>;
};

/** Handler function for an SVM `indexer.onSlot` registration. */
export type SvmOnSlotHandler<Config extends IndexerConfigTypes = GlobalConfig> = (
  args: SvmOnSlotHandlerArgs<Config>,
) => Promise<void>;

/** Options for an SVM `indexer.onSlot` registration. */
export type SvmOnSlotOptions<Config extends IndexerConfigTypes = GlobalConfig> = {
  /** Unique name for this slot handler. Used as the key in error messages
      and in persisted progress tracking. */
  readonly name: string;
  /** Optional predicate evaluated once per configured chain at registration
      time. Return `false` to skip a chain, `true` to match every slot, or
      a filter object to restrict by slot range and stride. */
  readonly where?: (args: SvmOnSlotWhereArgs<Config>) => SvmOnSlotWhereResult;
};

// ============== SVM onInstruction types ==============

/** Borsh-decoded params view of an instruction. Present whenever a
 * `ProgramSchema` was attached to the program (bundled, Anchor IDL, or
 * hand-written `accounts`/`args` in YAML). Absent when no schema applies or
 * the discriminator didn't match any registered instruction. */
export type SvmInstructionParams = {
  /** Schema-declared instruction name. */
  readonly name: string;
  /** Borsh-decoded args object. POC types this as `unknown`; narrow with a
   * locally-declared type until the typed-args codegen lands. */
  readonly args: unknown;
  /** Named accounts in schema order. Keys are exactly the schema-declared
   * names; values are base58 pubkeys. */
  readonly accounts: Readonly<Record<string, string>>;
  /** Accounts beyond the schema's named list (Anchor `remaining_accounts`,
   * IDL drift). Empty when counts match the schema. */
  readonly extraAccounts: readonly string[];
};

/** Permissive fallback shape for an instruction's `block`. The generated
 * per-instruction type narrows this to `slot`/`time`/`hash` (always present)
 * plus the selected `field_selection.block_fields`. */
export type SvmInstructionBlock = {
  /** Slot this instruction's block was matched in. */
  readonly slot: number;
  /** Unix block time (seconds). Absent only when HyperSync returned no block
   * row for this slot (rare; usually a skipped slot). */
  readonly time?: number;
  /** Block hash. Absent only when HyperSync returned no block row for this
   * slot (rare; usually a skipped slot). */
  readonly hash?: string;
  /** Block height. Select via `field_selection.block_fields`. */
  readonly height?: number;
  /** Parent slot. Select via `field_selection.block_fields`. */
  readonly parentSlot?: number;
  /** Parent block hash. Select via `field_selection.block_fields`. */
  readonly parentHash?: string;
};

export type SvmTokenBalance = {
  readonly account?: string;
  readonly mint?: string;
  readonly owner?: string;
  /** u64 decimal string. Cast with BigInt(...) for arithmetic. */
  readonly preAmount?: string;
  readonly postAmount?: string;
};

export type SvmLog = {
  readonly kind: string;
  readonly message: string;
};

/** A single Solana instruction delivered to an `onInstruction` handler.
 *
 * Carries the matched instruction's own fields (`programId`, `data`,
 * `accounts`, discriminator prefixes, `params`) plus the program/instruction
 * names, parent transaction, scoped logs, and block context. Parameterised
 * over `Params` so the per-(program, instruction) overload of
 * `onInstruction` can narrow `instruction.params` to the codegen-generated
 * `{ args, accounts }` shape.
 *
 * `data` and discriminator prefixes are `0x`-prefixed hex strings; accounts
 * are base58 strings. */
export type SvmInstruction<
  Params extends SvmInstructionParams = SvmInstructionParams,
  Tx = SvmTransaction,
  Block = SvmInstructionBlock,
> = {
  /** Program name as declared under `programs[].name` in `config.yaml`. */
  readonly programName: string;
  /** Instruction name as declared under `instructions[].name` in
   * `config.yaml`. */
  readonly instructionName: string;
  readonly programId: string;
  readonly data: string;
  readonly accounts: readonly string[];
  readonly instructionAddress: readonly number[];
  readonly isInner: boolean;
  readonly d1?: string;
  readonly d2?: string;
  readonly d4?: string;
  readonly d8?: string;
  /** Borsh-decoded params. Present when a schema is configured and matched. */
  readonly params?: Params;
  /** Parent transaction. Carries only the fields selected via this
   * instruction's `field_selection`; unselected fields are typed as
   * `FieldNotSelected<...>` so reading them is a compile error. Always present
   * (`{}` when no fields are selected). */
  readonly transaction: Tx;
  /** Present when the instruction's `include_logs` is `true`; only logs
   * scoped to this exact instruction (matching `instruction_address`). */
  readonly logs?: readonly SvmLog[];
  /** The block this instruction's slot belongs to. Carries `slot`/`time`/`hash`
   * (always present) plus the fields selected via this instruction's
   * `field_selection.block_fields`; unselected fields are typed as
   * `FieldNotSelected<...>`. */
  readonly block: Block;
};

/** Arguments passed to handlers registered via `indexer.onInstruction`. */
export type SvmOnInstructionHandlerArgs<
  Config extends IndexerConfigTypes = GlobalConfig,
  Instr extends SvmInstruction = SvmInstruction,
> = {
  readonly instruction: Instr;
  readonly context: SvmOnSlotContext<Config>;
};

/** Shape extracted from `Global.config.svm.programs[P][I]`. The codegen
 * emits `{ args: ...; accounts: ... }` per (program, instruction); this
 * helper turns that into a `SvmInstructionParams`-compatible record. */
type SvmParamsFromProgramTable<TInstr> = TInstr extends {
  args: infer A;
  accounts: infer Acc extends Readonly<Record<string, string>>;
}
  ? {
      readonly name: string;
      readonly args: A;
      readonly accounts: Acc;
      readonly extraAccounts: readonly string[];
    }
  : SvmInstructionParams;

/** Options for an SVM `indexer.onInstruction` registration. */
export type SvmOnInstructionOptions<P extends string = string, I extends string = string> = {
  /** Program name as declared under `chains[].programs[].name` in
   * `config.yaml`. */
  readonly program: P;
  /** Instruction name as declared under
   * `chains[].programs[].instructions[].name` in `config.yaml`. */
  readonly instruction: I;
};

/** Handler function for an SVM `indexer.onInstruction` registration. */
export type SvmOnInstructionHandler<
  Config extends IndexerConfigTypes = GlobalConfig,
> = (args: SvmOnInstructionHandlerArgs<Config>) => Promise<void>;

// ============== Indexer Types ==============

// Helper: Check if an ecosystem is configured. Single-ecosystem indexers only
// — see `SingleEcosystemChains` for how the result is consumed.
type HasEvm<Config> = "evm" extends keyof Config ? true : false;
type HasFuel<Config> = "fuel" extends keyof Config ? true : false;
type HasSvm<Config> = "svm" extends keyof Config ? true : false;

// EVM ecosystem type — includes chains plus handler registration methods.
// NOTE: options use inline { contract: C; event: E } shape for TypeScript inference.
// Using EvmOnEventOptions<Contracts[C][E]> would break inference since C/E can't be
// derived from indexed access types. The named EvmOnEventOptions type is for end-user
// reference; the inline shape here is structurally identical.
type EvmEcosystem<Config extends IndexerConfigTypes = GlobalConfig> =
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
type FuelEcosystem<Config extends IndexerConfigTypes = GlobalConfig> =
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

// Surfaced when an SVM indexer configures no `programs`, so there's no
// instruction to register a handler for. Mirrors `CodegenRequiredHint`: the
// string literal becomes the argument type, so any `onInstruction` call fails
// with this text naming the fix.
type SvmNoProgramsHint =
  "Add at least one entry under `svm.programs` in config.yaml to register instruction handlers with onInstruction.";

// SVM ecosystem type — chains plus instruction + slot handler methods.
type SvmEcosystem<Config extends IndexerConfigTypes = GlobalConfig> =
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
          } & (Config["svm"] extends {
            programs: infer Programs extends Record<string, Record<string, any>>;
          }
            ? {
                /**
                 * Register an instruction handler. Dispatch matches on
                 * `(programId, discriminator)` from the YAML config.
                 * `instruction.params.args` and
                 * `instruction.params.accounts` are typed from the
                 * program's Borsh schema (Anchor IDL, bundled, or
                 * hand-written `accounts`/`args` in YAML). `params` stays
                 * optional at runtime because schema-matching can fail on
                 * IDL drift or unknown discriminators.
                 */
                readonly onInstruction: <
                  P extends keyof Programs & string,
                  I extends keyof Programs[P] & string,
                >(
                  options: SvmOnInstructionOptions<P, I>,
                  handler: (
                    args: SvmOnInstructionHandlerArgs<
                      Config,
                      SvmInstruction<
                        SvmParamsFromProgramTable<Programs[P][I]>,
                        Programs[P][I]["transaction"],
                        Programs[P][I]["block"]
                      >
                    >,
                  ) => Promise<void>,
                ) => void;
              }
            : {
                /** No `programs` configured under `svm` in config.yaml, so
                 * there's nothing to register an instruction handler for. The
                 * rest parameter is typed as a string-literal hint so any call
                 * site fails with a message naming the fix. */
                readonly onInstruction: (
                  ...hint: SvmNoProgramsHint[]
                ) => void;
              })
        : never
      : never
    : never;

// Surfaced when the indexer has no configured ecosystem — typically because
// `envio codegen` hasn't been run yet, so `Global` isn't augmented and
// `GlobalConfig` resolves to `{}`. The handler methods are still present so
// IDE autocomplete shows them; their rest parameter is typed as a
// string-literal hint so any call site fails with an error message that
// names codegen as the fix. A rest parameter (rather than a single one)
// avoids "Expected N arguments" errors masking the hint.
type CodegenRequiredHint =
  "Run 'envio codegen' to generate handler types from config.yaml. Without codegen, the indexer has no contracts, chains, or events to register handlers for.";
type CodegenRequiredFallback = {
  readonly onEvent: (...hint: CodegenRequiredHint[]) => void;
  readonly onInstruction: (...hint: CodegenRequiredHint[]) => void;
  readonly onBlock: (...hint: CodegenRequiredHint[]) => void;
  readonly onSlot: (...hint: CodegenRequiredHint[]) => void;
  readonly contractRegister: (...hint: CodegenRequiredHint[]) => void;
};

// Single-ecosystem chains live at the root of the indexer object alongside
// the handler-registration methods. Multi-ecosystem indexers aren't
// supported by the runtime, so there's no nested `evm` / `fuel` / `svm`
// namespace variant.
type SingleEcosystemChains<Config extends IndexerConfigTypes = GlobalConfig> =
  HasEvm<Config> extends true
    ? EvmEcosystem<Config>
    : HasFuel<Config> extends true
    ? FuelEcosystem<Config>
    : HasSvm<Config> extends true
    ? SvmEcosystem<Config>
    : CodegenRequiredFallback;

/** Indexer type resolved from config. */
export type IndexerFromConfig<Config extends IndexerConfigTypes = GlobalConfig> = Prettify<
  {
    /** The indexer name from config.yaml. */
    readonly name: string;
    /** The indexer description from config.yaml. */
    readonly description: string | undefined;
    /**
     * Internal, unstable API that will be removed without notice. Registers a
     * callback fired once per chain affected by a reorg rollback, after the
     * rollback is durably written to the database. A throwing callback crashes
     * the indexer through the same path as a failed write.
     */
    readonly "~internalAndWillBeRemovedSoon_onRollbackCommit": (
      callback: (args: {
        readonly chainId: number;
        readonly rollbackToBlock: number;
      }) => Promise<void>,
    ) => void;
  } & SingleEcosystemChains<Config>
>;

// ============== Test Indexer Types ==============

/** Simulate item type for EVM ecosystem. */
type EvmSimulateItem<Config extends IndexerConfigTypes = GlobalConfig> =
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
type FuelSimulateItem<Config extends IndexerConfigTypes = GlobalConfig> =
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
type EvmTestIndexerChainConfig<Config extends IndexerConfigTypes = GlobalConfig> = {
  /** The block number to start processing from. Defaults to config startBlock or progressBlock+1. */
  startBlock?: number;
  /** The block number to stop processing at. Defaults to max simulate block number when simulate is provided. */
  endBlock?: number;
  /** Simulate items to process instead of fetching from real sources. */
  simulate?: EvmSimulateItem<Config>[];
};

/** Configuration for a single Fuel chain in the test indexer. */
type FuelTestIndexerChainConfig<Config extends IndexerConfigTypes = GlobalConfig> = {
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
type ConfigEntities<Config extends IndexerConfigTypes = GlobalConfig> =
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
type EntityChange<Config extends IndexerConfigTypes = GlobalConfig> = {
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
type EvmChainIds<Config extends IndexerConfigTypes = GlobalConfig> =
  Config["evm"] extends { chains: infer Chains }
    ? Chains extends Record<string, { id: number }>
      ? Chains[keyof Chains]["id"]
      : never
    : never;

type FuelChainIds<Config extends IndexerConfigTypes = GlobalConfig> =
  Config["fuel"] extends { chains: infer Chains }
    ? Chains extends Record<string, { id: number }>
      ? Chains[keyof Chains]["id"]
      : never
    : never;

type SvmChainIds<Config extends IndexerConfigTypes = GlobalConfig> =
  Config["svm"] extends { chains: infer Chains }
    ? Chains extends Record<string, { id: number }>
      ? Chains[keyof Chains]["id"]
      : never
    : never;

// Per-ecosystem chain config mappings
type EvmTestChains<Config extends IndexerConfigTypes = GlobalConfig> =
  HasEvm<Config> extends true
    ? { [K in EvmChainIds<Config>]?: EvmTestIndexerChainConfig<Config> }
    : {};

type FuelTestChains<Config extends IndexerConfigTypes = GlobalConfig> =
  HasFuel<Config> extends true
    ? { [K in FuelChainIds<Config>]?: FuelTestIndexerChainConfig<Config> }
    : {};

type SvmTestChains<Config extends IndexerConfigTypes = GlobalConfig> =
  HasSvm<Config> extends true
    ? { [K in SvmChainIds<Config>]?: SvmTestIndexerChainConfig }
    : {};

/** Process configuration for the test indexer, with chains keyed by chain ID. */
export type TestIndexerProcessConfig<Config extends IndexerConfigTypes = GlobalConfig> = {
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
type EvmTestEcosystem<Config extends IndexerConfigTypes = GlobalConfig> =
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

type FuelTestEcosystem<Config extends IndexerConfigTypes = GlobalConfig> =
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

type SvmTestEcosystem<Config extends IndexerConfigTypes = GlobalConfig> =
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

// Test-side single-ecosystem chain selector — parallel to SingleEcosystemChains.
type SingleEcosystemTestChains<Config extends IndexerConfigTypes = GlobalConfig> =
  HasEvm<Config> extends true
    ? EvmTestEcosystem<Config>
    : HasFuel<Config> extends true
    ? FuelTestEcosystem<Config>
    : HasSvm<Config> extends true
    ? SvmTestEcosystem<Config>
    : CodegenRequiredFallback;

/**
 * Test indexer type resolved from config.
 * Allows running the indexer for specific block ranges and inspecting results.
 */
export type TestIndexerFromConfig<Config extends IndexerConfigTypes = GlobalConfig> = {
  /** Process blocks for the specified chains and return progress with checkpoints and changes. */
  process: (
    config: Prettify<TestIndexerProcessConfig<Config>>
  ) => Promise<{
    /** Changes happened during the processing. */
    readonly changes: readonly EntityChange<Config>[];
  }>;
} & SingleEcosystemTestChains<Config> & {
  /** Entity operations for direct manipulation outside of handlers. */
  readonly [K in keyof ConfigEntities<Config>]: TestIndexerEntityOperations<
    ConfigEntities<Config>[K]
  >;
};

// ============== Project-bound aliases (augmented via Global) ==============

// One place to read the augmented shape. `extends { … }` checks survive when
// GlobalConfig is `{}` (un-augmented) — direct `GlobalConfig["evm"]` indexing
// would be a type error in that fallback case.
type EvmChainsT     = GlobalConfig extends { evm:  { chains:    infer X extends Record<string, { id: number }> } } ? X : {};
type EvmContractsT  = GlobalConfig extends { evm:  { contracts: infer X extends Record<string, Record<string, any>> } } ? X : {};
type FuelChainsT    = GlobalConfig extends { fuel: { chains:    infer X extends Record<string, { id: number }> } } ? X : {};
type FuelContractsT = GlobalConfig extends { fuel: { contracts: infer X extends Record<string, Record<string, any>> } } ? X : {};
type SvmChainsT     = GlobalConfig extends { svm:  { chains:    infer X extends Record<string, { id: number }> } } ? X : {};
type SvmProgramsT   = GlobalConfig extends { svm:  { programs:  infer X extends Record<string, Record<string, any>> } } ? X : {};
type EntitiesT      = GlobalConfig extends { entities: infer X extends Record<string, object> } ? X : {};
type EnumsT         = GlobalConfig extends { enums: infer X extends Record<string, any> } ? X : {};

/** Union of all configured EVM chain names. */
export type EvmChainName     = IsEmptyObject<EvmChainsT>     extends true ? NotConfigured<"EvmChainName",     "Configure EVM chains">      : keyof EvmChainsT     & string;
/** Union of all configured EVM contract names. */
export type EvmContractName  = IsEmptyObject<EvmContractsT>  extends true ? NotConfigured<"EvmContractName",  "Configure EVM contracts">   : keyof EvmContractsT  & string;
/** Union of all configured Fuel chain names. */
export type FuelChainName    = IsEmptyObject<FuelChainsT>    extends true ? NotConfigured<"FuelChainName",    "Configure Fuel chains">     : keyof FuelChainsT    & string;
/** Union of all configured Fuel contract names. */
export type FuelContractName = IsEmptyObject<FuelContractsT> extends true ? NotConfigured<"FuelContractName", "Configure Fuel contracts">  : keyof FuelContractsT & string;
/** Union of all configured SVM chain names. */
export type SvmChainName     = IsEmptyObject<SvmChainsT>     extends true ? NotConfigured<"SvmChainName",     "Configure SVM chains">      : keyof SvmChainsT     & string;

/** Union of all configured EVM chain IDs. */
export type EvmChainId  = IsEmptyObject<EvmChainsT>  extends true ? NotConfigured<"EvmChainId",  "Configure EVM chains">  : EvmChainsT [keyof EvmChainsT ]["id"];
/** Union of all configured Fuel chain IDs. */
export type FuelChainId = IsEmptyObject<FuelChainsT> extends true ? NotConfigured<"FuelChainId", "Configure Fuel chains"> : FuelChainsT[keyof FuelChainsT]["id"];
/** Union of all configured SVM chain IDs. */
export type SvmChainId  = IsEmptyObject<SvmChainsT>  extends true ? NotConfigured<"SvmChainId",  "Configure SVM chains">  : SvmChainsT [keyof SvmChainsT ]["id"];

/** The SVM parent-transaction type generated from this project's
 *  `field_selection`: the union of every instruction's `transaction` shape,
 *  with unselected fields typed as `FieldNotSelected<...>`. Resolves to a
 *  `NotConfigured` hint until `envio codegen` augments {@link Global}. */
export type SvmTransaction = IsEmptyObject<SvmProgramsT> extends true
  ? NotConfigured<"SvmTransaction", "Configure SVM programs">
  : {
      [P in keyof SvmProgramsT]: {
        [I in keyof SvmProgramsT[P]]: SvmProgramsT[P][I]["transaction"];
      }[keyof SvmProgramsT[P]];
    }[keyof SvmProgramsT];

/** Lookup an EVM event type by contract and event name. Without generics,
 *  resolves to the discriminated union of every EVM event in the project. */
export type EvmEvent<
  TContractName extends keyof EvmContractsT = keyof EvmContractsT,
  TEventName extends string = string,
> = IsEmptyObject<EvmContractsT> extends true
  ? NotConfigured<"EvmEvent", "Configure EVM contracts">
  : {
      [C in TContractName]: EvmContractsT[C][TEventName & keyof EvmContractsT[C]];
    }[TContractName];

/** Lookup a Fuel event type by contract and event name. Without generics,
 *  resolves to the discriminated union of every Fuel event in the project. */
export type FuelEvent<
  TContractName extends keyof FuelContractsT = keyof FuelContractsT,
  TEventName extends string = string,
> = IsEmptyObject<FuelContractsT> extends true
  ? NotConfigured<"FuelEvent", "Configure Fuel contracts">
  : {
      [C in TContractName]: FuelContractsT[C][TEventName & keyof FuelContractsT[C]];
    }[TContractName];

/** The indexer instance bound to this project's configuration. */
export type Indexer = IndexerFromConfig<GlobalConfig>;

/** The test indexer instance bound to this project's configuration. */
export type TestIndexer = TestIndexerFromConfig<GlobalConfig>;

/** Union of all entity names defined in `schema.graphql`. */
export type EntityName = keyof EntitiesT & string;
/** Lookup an entity type by name (e.g. `Entity<"Account">`). */
export type Entity<TName extends EntityName> = EntitiesT[TName];

/** Union of all enum names defined in `schema.graphql`. */
export type EnumName = keyof EnumsT & string;
/** Lookup an enum value type by name (e.g. `Enum<"AccountType">`). */
export type Enum<TName extends EnumName> = EnumsT[TName];

// ============== Runtime values ==============

/** The indexer instance. Register handlers with `indexer.onEvent`,
 *  `indexer.contractRegister`, `indexer.onBlock`, etc. */
export const indexer: Indexer;

/** Construct a {@link TestIndexer} for use in unit tests. */
export const createTestIndexer: () => TestIndexer;
