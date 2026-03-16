// The file with public API.
// Should be an entry point after we get rid of the generated project.
// Don't forget to keep index.d.ts in sync with this file.

@genType
type blockEvent = {number: int}

@genType
type fuelBlockEvent = {height: int}

// ============== EVM Block & Transaction Types ==============
// Static types exposed to users. All fields are always visible on the type.
// At runtime, accessing a field not in field_selection throws a friendly error via proxy.
// For TS users: index.d.ts provides JSDoc descriptions for all fields.
// For ReScript users: all fields are required on the type; inherently nullable
// fields use option<T>. The runtime proxy validates field access at runtime.

/** EVM block data. `number`, `timestamp`, and `hash` are always available.
    Other fields require `field_selection` configuration in config.yaml. */
@genType
type evmBlock = {
  /** The block number (height) in the chain. Always available. */
  number: int,
  /** The unix timestamp of when the block was mined. Always available. */
  timestamp: int,
  /** The hash of the block. Always available. */
  hash: string,
  /** The hash of the parent block. */
  parentHash: string,
  /** The nonce of the block, used in proof-of-work. None for proof-of-stake blocks. */
  nonce: option<bigint>,
  /** The SHA3 hash of the uncles data in the block. */
  sha3Uncles: string,
  /** The bloom filter for the logs of the block. */
  logsBloom: string,
  /** The root of the transaction trie of the block. */
  transactionsRoot: string,
  /** The root of the state trie of the block. */
  stateRoot: string,
  /** The root of the receipts trie of the block. */
  receiptsRoot: string,
  /** The address of the miner/validator who mined this block. */
  miner: Address.t,
  /** The difficulty for this block. None for proof-of-stake blocks. */
  difficulty: option<bigint>,
  /** The total difficulty of the chain until this block. None for proof-of-stake blocks. */
  totalDifficulty: option<bigint>,
  /** The extra data included in the block by the miner. */
  extraData: string,
  /** The size of this block in bytes. */
  size: bigint,
  /** The maximum gas allowed in this block. */
  gasLimit: bigint,
  /** The total gas used by all transactions in this block. */
  gasUsed: bigint,
  /** The list of uncle block hashes. */
  uncles: option<array<string>>,
  /** The base fee per gas in this block (EIP-1559). None for pre-London blocks. */
  baseFeePerGas: option<bigint>,
  /** The total amount of blob gas consumed by transactions in this block (EIP-4844). */
  blobGasUsed: option<bigint>,
  /** The running total of blob gas consumed in excess of the target (EIP-4844). */
  excessBlobGas: option<bigint>,
  /** The root hash of the parent beacon block (EIP-4788). */
  parentBeaconBlockRoot: option<string>,
  /** The root hash of the withdrawals trie (EIP-4895). */
  withdrawalsRoot: option<string>,
  /** The L1 block number associated with this L2 block (L2 chains only). */
  l1BlockNumber: option<int>,
  /** The number of messages sent in this block (Arbitrum). */
  sendCount: option<string>,
  /** The Merkle root of the outbox messages (Arbitrum). */
  sendRoot: option<string>,
  /** The mix hash used in proof-of-work. */
  mixHash: option<string>,
}

/** EVM transaction data. All fields require `field_selection` configuration. */
@genType
type evmTransaction = Internal.evmTransactionFields

/** Fuel block data. */
@genType
type fuelBlock = {
  /** The unique identifier of the block. */
  id: string,
  /** The block height (number). */
  height: int,
  /** The unix timestamp of the block. */
  time: int,
}

/** Fuel transaction data. */
@genType
type fuelTransaction = {
  /** The unique identifier of the transaction. */
  id: string,
}

@genType
type svmOnBlockArgs<'context> = {slot: int, context: 'context}

@genType
type onBlockArgs<'block, 'context> = {
  block: 'block,
  context: 'context,
}

@genType
type onBlockOptions<'chain> = {
  name: string,
  chain: 'chain,
  interval?: int,
  startBlock?: int,
  endBlock?: int,
}

type whereOperator<'fieldType> = {
  /** Matches entities where the field equals the given value. */
  _eq?: 'fieldType,
  /** Matches entities where the field is strictly greater than the given value. */
  _gt?: 'fieldType,
  /** Matches entities where the field is strictly less than the given value. */
  _lt?: 'fieldType,
  /** Matches entities where the field is greater than or equal to the given value. */
  _gte?: 'fieldType,
  /** Matches entities where the field is less than or equal to the given value. */
  _lte?: 'fieldType,
  /** Matches entities where the field equals any of the given values. */
  _in?: array<'fieldType>,
}

@genType.import(("./Types.ts", "Logger"))
type logger = {
  debug: 'params. (string, ~params: {..} as 'params=?) => unit,
  info: 'params. (string, ~params: {..} as 'params=?) => unit,
  warn: 'params. (string, ~params: {..} as 'params=?) => unit,
  error: 'params. (string, ~params: {..} as 'params=?) => unit,
  errorWithExn: (string, exn) => unit,
}

@@warning("-30") // Duplicated type names (input)
@genType.import(("./Types.ts", "Effect"))
type rec effect<'input, 'output>
@genType @unboxed
and rateLimitDuration =
  | @as("second") Second
  | @as("minute") Minute
  | Milliseconds(int)
@genType @unboxed
and rateLimit =
  | @as(false) Disable
  | Enable({calls: int, per: rateLimitDuration})
@genType
and effectOptions<'input, 'output> = {
  /** The name of the effect. Used for logging and debugging. */
  name: string,
  /** The input schema of the effect. */
  input: S.t<'input>,
  /** The output schema of the effect. */
  output: S.t<'output>,
  /** Rate limit for the effect. Set to false to disable or provide {calls: number, per: "second" | "minute"} to enable. */
  rateLimit: rateLimit,
  /** Whether the effect should be cached. */
  cache?: bool,
}
@genType.import(("./Types.ts", "EffectContext"))
and effectContext = {
  log: logger,
  effect: 'input 'output. (effect<'input, 'output>, 'input) => promise<'output>,
  mutable cache: bool,
}
@genType
and effectArgs<'input> = {
  input: 'input,
  context: effectContext,
}
@@warning("+30")

let durationToMs = (duration: rateLimitDuration) =>
  switch duration {
  | Second => 1000
  | Minute => 60000
  | Milliseconds(ms) => ms
  }

let createEffect = (
  options: effectOptions<'input, 'output>,
  handler: effectArgs<'input> => promise<'output>,
) => {
  let outputSchema =
    S.schema(_ => options.output)->(Utils.magic: S.t<S.t<'output>> => S.t<Internal.effectOutput>)
  let itemSchema = S.schema((s): Internal.effectCacheItem => {
    id: s.matches(S.string),
    output: s.matches(outputSchema),
  })
  {
    name: options.name,
    handler: handler->(
      Utils.magic: (effectArgs<'input> => promise<'output>) => Internal.effectArgs => promise<
        Internal.effectOutput,
      >
    ),
    activeCallsCount: 0,
    prevCallStartTimerRef: %raw(`null`),
    // This is the way to make the createEffect API
    // work without the need for users to call S.schema themselves,
    // but simply pass the desired object/tuple/etc.
    // If they pass a schem, it'll also work.
    input: S.schema(_ => options.input)->(
      Utils.magic: S.t<S.t<'input>> => S.t<Internal.effectInput>
    ),
    output: outputSchema,
    storageMeta: {
      table: Internal.makeCacheTable(~effectName=options.name),
      outputSchema,
      itemSchema,
    },
    defaultShouldCache: switch options.cache {
    | Some(true) => true
    | _ => false
    },
    rateLimit: switch options.rateLimit {
    | Disable => None
    | Enable({calls, per}) =>
      Some({
        callsPerDuration: calls,
        durationMs: per->durationToMs,
        availableCalls: calls,
        windowStartTime: Js.Date.now(),
        queueCount: 0,
        nextWindowPromise: None,
      })
    },
  }->(Utils.magic: Internal.effect => effect<'input, 'output>)
}
