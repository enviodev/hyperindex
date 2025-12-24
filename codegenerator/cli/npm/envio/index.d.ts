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
 * Used as a constraint for IndexerFromConfig to allow usage without codegen.
 */
export type IndexerConfig = {
  /** The indexer name. */
  name: string;
  /** The indexer description. */
  description?: string;
  /** EVM ecosystem configuration. */
  evm?: {
    /** Chain configurations keyed by chain name. */
    chains: Record<string, EvmChainConfig>;
  };
  /** Fuel ecosystem configuration. */
  fuel?: {
    /** Chain configurations keyed by chain name. */
    chains: Record<string, FuelChainConfig>;
  };
  /** SVM ecosystem configuration. */
  svm?: {
    /** Chain configurations keyed by chain name. */
    chains: Record<string, SvmChainConfig>;
  };
};

// ============== EVM Types ==============

// Helper to extract config from Global if it exists
type GlobalIndexerConfig = Global extends { config: infer C } ? C : never;

/** Union of all configured EVM chain names. */
export type EvmChainName = GlobalIndexerConfig extends { evm: infer Evm }
  ? Evm extends {
      chains: Record<infer K extends string, any>;
    }
    ? K
    : "EvmChainName is not available. Configure EVM chains in config.yaml and run 'pnpm envio codegen'"
  : "EvmChainName is not available. Configure EVM chains in config.yaml and run 'pnpm envio codegen'";

/** Union of all configured EVM chain IDs. */
export type EvmChainId = GlobalIndexerConfig extends { evm: infer Evm }
  ? Evm extends {
      chains: Record<string, { id: infer T extends number }>;
    }
    ? T
    : "EvmChainId is not available. Configure EVM chains in config.yaml and run 'pnpm envio codegen'"
  : "EvmChainId is not available. Configure EVM chains in config.yaml and run 'pnpm envio codegen'";

/** EVM chain configuration (for IndexerConfig). */
type EvmChainConfig<Id extends number = number> = {
  /** The chain ID. */
  readonly id: Id;
  /** The block number indexing starts from. */
  readonly startBlock: number;
  /** The block number indexing stops at (if configured). */
  readonly endBlock?: number;
};

/** EVM chain value (for runtime Indexer). */
type EvmChain<Id extends number = number> = {
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

// ============== Fuel Types ==============

/** Union of all configured Fuel chain names. */
export type FuelChainName = GlobalIndexerConfig extends { fuel: infer Fuel }
  ? Fuel extends {
      chains: Record<infer K extends string, any>;
    }
    ? K
    : "FuelChainName is not available. Configure Fuel chains in config.yaml and run 'pnpm envio codegen'"
  : "FuelChainName is not available. Configure Fuel chains in config.yaml and run 'pnpm envio codegen'";

/** Union of all configured Fuel chain IDs. */
export type FuelChainId = GlobalIndexerConfig extends { fuel: infer Fuel }
  ? Fuel extends {
      chains: Record<string, { id: infer T extends number }>;
    }
    ? T
    : "FuelChainId is not available. Configure Fuel chains in config.yaml and run 'pnpm envio codegen'"
  : "FuelChainId is not available. Configure Fuel chains in config.yaml and run 'pnpm envio codegen'";

/** Fuel chain configuration (for IndexerConfig). */
type FuelChainConfig<Id extends number = number> = {
  /** The chain ID. */
  readonly id: Id;
  /** The block number indexing starts from. */
  readonly startBlock: number;
  /** The block number indexing stops at (if configured). */
  readonly endBlock?: number;
};

/** Fuel chain value (for runtime Indexer). */
type FuelChain<Id extends number = number> = {
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

// ============== SVM (Solana) Types ==============

/** Union of all configured SVM chain names. */
export type SvmChainName = GlobalIndexerConfig extends { svm: infer Svm }
  ? Svm extends {
      chains: Record<infer K extends string, any>;
    }
    ? K
    : "SvmChainName is not available. Configure SVM chains in config.yaml and run 'pnpm envio codegen'"
  : "SvmChainName is not available. Configure SVM chains in config.yaml and run 'pnpm envio codegen'";

/** Union of all configured SVM chain IDs. */
export type SvmChainId = GlobalIndexerConfig extends { svm: infer Svm }
  ? Svm extends {
      chains: Record<string, { id: infer T extends number }>;
    }
    ? T
    : "SvmChainId is not available. Configure SVM chains in config.yaml and run 'pnpm envio codegen'"
  : "SvmChainId is not available. Configure SVM chains in config.yaml and run 'pnpm envio codegen'";

/** SVM chain configuration (for IndexerConfig). */
type SvmChainConfig<Id extends number = number> = {
  /** The chain ID. */
  readonly id: Id;
  /** The block number indexing starts from. */
  readonly startBlock: number;
  /** The block number indexing stops at (if configured). */
  readonly endBlock?: number;
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
type EvmEcosystem<Config extends IndexerConfig = GlobalIndexerConfig> =
  "evm" extends keyof Config
    ? Config["evm"] extends { chains: infer Chains }
      ? Chains extends Record<string, { id: number }>
        ? {
            /** Array of all EVM chain IDs. */
            readonly chainIds: readonly Chains[keyof Chains]["id"][];
            /** Per-chain configuration keyed by chain name or ID. */
            readonly chains: {
              readonly [K in Chains[keyof Chains]["id"]]: EvmChain<K>;
            } & {
              readonly [K in keyof Chains]: EvmChain<Chains[K]["id"]>;
            };
          }
        : never
      : never
    : never;

// Fuel ecosystem type
type FuelEcosystem<Config extends IndexerConfig = GlobalIndexerConfig> =
  "fuel" extends keyof Config
    ? Config["fuel"] extends { chains: infer Chains }
      ? Chains extends Record<string, { id: number }>
        ? {
            /** Array of all Fuel chain IDs. */
            readonly chainIds: readonly Chains[keyof Chains]["id"][];
            /** Per-chain configuration keyed by chain name or ID. */
            readonly chains: {
              readonly [K in Chains[keyof Chains]["id"]]: FuelChain<K>;
            } & {
              readonly [K in keyof Chains]: FuelChain<Chains[K]["id"]>;
            };
          }
        : never
      : never
    : never;

// SVM ecosystem type
type SvmEcosystem<Config extends IndexerConfig = GlobalIndexerConfig> =
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
type SingleEcosystemChains<Config extends IndexerConfig> =
  HasEvm<Config> extends true
    ? EvmEcosystem<Config>
    : HasFuel<Config> extends true
    ? FuelEcosystem<Config>
    : HasSvm<Config> extends true
    ? SvmEcosystem<Config>
    : {};

// Multi-ecosystem chains (namespaced by ecosystem)
type MultiEcosystemChains<Config extends IndexerConfig> =
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
export type IndexerFromConfig<Config extends IndexerConfig> = {
  /** The indexer name from config.yaml. */
  readonly name: Config["name"];
  /** The indexer description from config.yaml. */
  readonly description: Config["description"];
} & (EcosystemCount<Config> extends 1
  ? SingleEcosystemChains<Config>
  : MultiEcosystemChains<Config>);

/** The indexer type. */
export type Indexer = Global extends {
  config: infer Config extends IndexerConfig;
}
  ? IndexerFromConfig<Config>
  : "The Indexer type is not available. Run 'pnpm envio codegen' to generate types";
