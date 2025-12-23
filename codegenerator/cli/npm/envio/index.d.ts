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
  export const evmChainId: Sury.Schema<EvmChainId, EvmChainId>;
  export const fuelChainId: Sury.Schema<FuelChainId, FuelChainId>;
  export const svmChainId: Sury.Schema<SvmChainId, SvmChainId>;
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
 * This interface is augmented by generated/envio.d.ts with project-specific chain IDs.
 *
 * @example
 * // In generated/envio.d.ts:
 * declare module "envio" {
 *   interface IndexerConfig {
 *     evm: { chainIds: readonly [1, 137] };
 *   }
 * }
 */
export interface IndexerConfig {}

/**
 * Shape of the indexer configuration.
 * Used as a constraint for IndexerFromConfig to allow usage without codegen.
 */
export type IndexerConfigShape = {
  evm?: { chainIds: readonly number[] };
  fuel?: { chainIds: readonly number[] };
  svm?: { chainIds: readonly number[] };
};

// ============== EVM Types ==============

/** Union of all configured EVM chain IDs. */
export type EvmChainId = "evm" extends keyof IndexerConfig
  ? IndexerConfig["evm"] extends { chainIds: readonly (infer T)[] }
    ? T
    : never
  : "EvmChainId is not available. Configure EVM chains in config.yaml and run 'pnpm envio codegen'";

/** EVM chain configuration. */
export type EvmChain<Id extends number = number> = {
  /** The chain ID. */
  readonly id: Id;
  /** The block number indexing starts from. */
  readonly startBlock: number;
  /** The block number indexing stops at (if configured). */
  readonly endBlock: number | undefined;
};

/** Record of EVM chain configurations keyed by chain ID. */
export type EvmChains = "evm" extends keyof IndexerConfig
  ? IndexerConfig["evm"] extends {
      chainIds: readonly (infer T extends number)[];
    }
    ? { readonly [K in T]: EvmChain<K> }
    : never
  : "EvmChains is not available. Configure EVM chains in config.yaml and run 'pnpm envio codegen'";

// ============== Fuel Types ==============

/** Union of all configured Fuel chain IDs. */
export type FuelChainId = "fuel" extends keyof IndexerConfig
  ? IndexerConfig["fuel"] extends { chainIds: readonly (infer T)[] }
    ? T
    : never
  : "FuelChainId is not available. Configure Fuel chains in config.yaml and run 'pnpm envio codegen'";

/** Fuel chain configuration. */
export type FuelChain<Id extends number = number> = {
  /** The chain ID. */
  readonly id: Id;
  /** The block number indexing starts from. */
  readonly startBlock: number;
  /** The block number indexing stops at (if configured). */
  readonly endBlock: number | undefined;
};

/** Record of Fuel chain configurations keyed by chain ID. */
export type FuelChains = "fuel" extends keyof IndexerConfig
  ? IndexerConfig["fuel"] extends {
      chainIds: readonly (infer T extends number)[];
    }
    ? { readonly [K in T]: FuelChain<K> }
    : never
  : "FuelChains is not available. Configure Fuel chains in config.yaml and run 'pnpm envio codegen'";

// ============== SVM (Solana) Types ==============

/** Union of all configured SVM chain IDs. */
export type SvmChainId = "svm" extends keyof IndexerConfig
  ? IndexerConfig["svm"] extends { chainIds: readonly (infer T)[] }
    ? T
    : never
  : "SvmChainId is not available. Configure SVM chains in config.yaml and run 'pnpm envio codegen'";

/** SVM chain configuration. */
export type SvmChain<Id extends number = number> = {
  /** The chain ID. */
  readonly id: Id;
  /** The block number indexing starts from. */
  readonly startBlock: number;
  /** The block number indexing stops at (if configured). */
  readonly endBlock: number | undefined;
};

/** Record of SVM chain configurations keyed by chain ID. */
export type SvmChains = "svm" extends keyof IndexerConfig
  ? IndexerConfig["svm"] extends {
      chainIds: readonly (infer T extends number)[];
    }
    ? { readonly [K in T]: SvmChain<K> }
    : never
  : "SvmChains is not available. Configure SVM chains in config.yaml and run 'pnpm envio codegen'";

// ============== Indexer Type ==============

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

// Single ecosystem chains (flattened at root level)
type SingleEcosystemChains<Config> = HasEvm<Config> extends true
  ? {
      /** Array of all chain IDs this indexer operates on. */
      readonly chainIds: readonly EvmChainId[];
      /** Per-chain configuration keyed by chain ID. */
      readonly chains: EvmChains;
    }
  : HasFuel<Config> extends true
  ? {
      /** Array of all chain IDs this indexer operates on. */
      readonly chainIds: readonly FuelChainId[];
      /** Per-chain configuration keyed by chain ID. */
      readonly chains: FuelChains;
    }
  : HasSvm<Config> extends true
  ? {
      /** Array of all chain IDs this indexer operates on. */
      readonly chainIds: readonly SvmChainId[];
      /** Per-chain configuration keyed by chain ID. */
      readonly chains: SvmChains;
    }
  : {};

// Multi-ecosystem chains (namespaced by ecosystem)
type MultiEcosystemChains<Config> = (HasEvm<Config> extends true
  ? {
      /** EVM ecosystem configuration. */
      readonly evm: {
        /** Array of EVM chain IDs. */
        readonly chainIds: readonly EvmChainId[];
        /** Per-chain configuration keyed by chain ID. */
        readonly chains: EvmChains;
      };
    }
  : {}) &
  (HasFuel<Config> extends true
    ? {
        /** Fuel ecosystem configuration. */
        readonly fuel: {
          /** Array of Fuel chain IDs. */
          readonly chainIds: readonly FuelChainId[];
          /** Per-chain configuration keyed by chain ID. */
          readonly chains: FuelChains;
        };
      }
    : {}) &
  (HasSvm<Config> extends true
    ? {
        /** SVM ecosystem configuration. */
        readonly svm: {
          /** Array of SVM chain IDs. */
          readonly chainIds: readonly SvmChainId[];
          /** Per-chain configuration keyed by chain ID. */
          readonly chains: SvmChains;
        };
      }
    : {});

/**
 * Indexer type resolved from config, adapting chain properties based on configured ecosystems.
 * - Single ecosystem: chainIds and chains are at the root level.
 * - Multiple ecosystems: chainIds and chains are namespaced by ecosystem (evm, fuel, svm).
 */
export type IndexerFromConfig<Config extends IndexerConfigShape> = {
  /** The indexer name from config.yaml. */
  readonly name: string;
  /** The indexer description from config.yaml. */
  readonly description: string | undefined;
} & (EcosystemCount<Config> extends 1
  ? SingleEcosystemChains<Config>
  : MultiEcosystemChains<Config>);

/** The indexer type. */
export type Indexer = EcosystemCount<IndexerConfig> extends 0
  ? "The Indexer type is not available. Run 'pnpm envio codegen' to generate types"
  : IndexerFromConfig<IndexerConfig>;
