type eventParams
type eventBlock
type eventTransaction

// Field name variants for type-safe field selection.
// @unboxed compiles to plain strings at runtime, matching JS property names.
@unboxed
type evmBlockField =
  | @as("number") Number
  | @as("timestamp") Timestamp
  | @as("hash") Hash
  | @as("parentHash") ParentHash
  | @as("nonce") Nonce
  | @as("sha3Uncles") Sha3Uncles
  | @as("logsBloom") LogsBloom
  | @as("transactionsRoot") TransactionsRoot
  | @as("stateRoot") StateRoot
  | @as("receiptsRoot") ReceiptsRoot
  | @as("miner") Miner
  | @as("difficulty") Difficulty
  | @as("totalDifficulty") TotalDifficulty
  | @as("extraData") ExtraData
  | @as("size") Size
  | @as("gasLimit") GasLimit
  | @as("gasUsed") GasUsed
  | @as("uncles") Uncles
  | @as("baseFeePerGas") BaseFeePerGas
  | @as("blobGasUsed") BlobGasUsed
  | @as("excessBlobGas") ExcessBlobGas
  | @as("parentBeaconBlockRoot") ParentBeaconBlockRoot
  | @as("withdrawalsRoot") WithdrawalsRoot
  | @as("l1BlockNumber") L1BlockNumber
  | @as("sendCount") SendCount
  | @as("sendRoot") SendRoot
  | @as("mixHash") MixHash

@unboxed
type evmTransactionField =
  | @as("transactionIndex") TransactionIndex
  | @as("hash") Hash
  | @as("from") From
  | @as("to") To
  | @as("gas") Gas
  | @as("gasPrice") GasPrice
  | @as("maxPriorityFeePerGas") MaxPriorityFeePerGas
  | @as("maxFeePerGas") MaxFeePerGas
  | @as("cumulativeGasUsed") CumulativeGasUsed
  | @as("effectiveGasPrice") EffectiveGasPrice
  | @as("gasUsed") GasUsed
  | @as("input") Input
  | @as("nonce") Nonce
  | @as("value") Value
  | @as("v") V
  | @as("r") R
  | @as("s") S
  | @as("contractAddress") ContractAddress
  | @as("logsBloom") LogsBloom
  | @as("root") Root
  | @as("status") Status
  | @as("yParity") YParity
  | @as("maxFeePerBlobGas") MaxFeePerBlobGas
  | @as("blobVersionedHashes") BlobVersionedHashes
  | @as("type") Type
  | @as("l1Fee") L1Fee
  | @as("l1GasPrice") L1GasPrice
  | @as("l1GasUsed") L1GasUsed
  | @as("l1FeeScalar") L1FeeScalar
  | @as("gasUsedForL1") GasUsedForL1
  | @as("accessList") AccessList
  | @as("authorizationList") AuthorizationList

let allEvmBlockFields: array<evmBlockField> = [
  Number,
  Timestamp,
  Hash,
  ParentHash,
  Nonce,
  Sha3Uncles,
  LogsBloom,
  TransactionsRoot,
  StateRoot,
  ReceiptsRoot,
  Miner,
  Difficulty,
  TotalDifficulty,
  ExtraData,
  Size,
  GasLimit,
  GasUsed,
  Uncles,
  BaseFeePerGas,
  BlobGasUsed,
  ExcessBlobGas,
  ParentBeaconBlockRoot,
  WithdrawalsRoot,
  L1BlockNumber,
  SendCount,
  SendRoot,
  MixHash,
]
let evmBlockFieldSchema = S.enum(allEvmBlockFields)

let allEvmTransactionFields: array<evmTransactionField> = [
  TransactionIndex,
  Hash,
  From,
  To,
  Gas,
  GasPrice,
  MaxPriorityFeePerGas,
  MaxFeePerGas,
  CumulativeGasUsed,
  EffectiveGasPrice,
  GasUsed,
  Input,
  Nonce,
  Value,
  V,
  R,
  S,
  ContractAddress,
  LogsBloom,
  Root,
  Status,
  YParity,
  MaxFeePerBlobGas,
  BlobVersionedHashes,
  Type,
  L1Fee,
  L1GasPrice,
  L1GasUsed,
  L1FeeScalar,
  GasUsedForL1,
  AccessList,
  AuthorizationList,
]
let evmTransactionFieldSchema = S.enum(allEvmTransactionFields)

// SVM transaction fields. Order mirrors the Rust `SvmTxField` ordinals (the bit
// position in the selection mask) and `Svm.res` `transactionFields`.
type svmTransactionField =
  | @as("transactionIndex") TransactionIndex
  | @as("signatures") Signatures
  | @as("feePayer") FeePayer
  | @as("success") Success
  | @as("err") Err
  | @as("fee") Fee
  | @as("computeUnitsConsumed") ComputeUnitsConsumed
  | @as("accountKeys") AccountKeys
  | @as("recentBlockhash") RecentBlockhash
  | @as("version") Version
  | @as("tokenBalances") TokenBalances

let allSvmTransactionFields: array<svmTransactionField> = [
  TransactionIndex,
  Signatures,
  FeePayer,
  Success,
  Err,
  Fee,
  ComputeUnitsConsumed,
  AccountKeys,
  RecentBlockhash,
  Version,
  TokenBalances,
]
let svmTransactionFieldSchema = S.enum(allSvmTransactionFields)

// SVM block fields selectable via `field_selection.block_fields`. `slot`/`time`/
// `hash` are always included, so they aren't part of this set.
type svmBlockField =
  | @as("height") Height
  | @as("parentSlot") ParentSlot
  | @as("parentHash") ParentHash

let allSvmBlockFields: array<svmBlockField> = [Height, ParentSlot, ParentHash]
let svmBlockFieldSchema = S.enum(allSvmBlockFields)

// Static sets of nullable field names — used by RpcSource and HyperSyncSource to wrap schemas with S.nullable
let evmNullableBlockFields = Utils.Set.fromArray(
  (
    [
      Nonce,
      Difficulty,
      TotalDifficulty,
      Uncles,
      BaseFeePerGas,
      BlobGasUsed,
      ExcessBlobGas,
      ParentBeaconBlockRoot,
      WithdrawalsRoot,
      L1BlockNumber,
      SendCount,
      SendRoot,
      MixHash,
    ]: array<evmBlockField>
  ),
)
let evmNullableTransactionFields = Utils.Set.fromArray(
  (
    [
      GasPrice,
      V,
      R,
      S,
      YParity,
      MaxPriorityFeePerGas,
      MaxFeePerGas,
      MaxFeePerBlobGas,
      BlobVersionedHashes,
      ContractAddress,
      Root,
      Status,
      L1Fee,
      L1GasPrice,
      L1GasUsed,
      L1FeeScalar,
      GasUsedForL1,
      From,
      To,
      Type,
    ]: array<evmTransactionField>
  ),
)

type evmBlockInput = {
  number?: int,
  timestamp?: int,
  hash?: string,
  parentHash?: string,
  nonce?: bigint,
  sha3Uncles?: string,
  logsBloom?: string,
  transactionsRoot?: string,
  stateRoot?: string,
  receiptsRoot?: string,
  miner?: Address.t,
  difficulty?: bigint,
  totalDifficulty?: bigint,
  extraData?: string,
  size?: bigint,
  gasLimit?: bigint,
  gasUsed?: bigint,
  uncles?: array<string>,
  baseFeePerGas?: bigint,
  blobGasUsed?: bigint,
  excessBlobGas?: bigint,
  parentBeaconBlockRoot?: string,
  withdrawalsRoot?: string,
  l1BlockNumber?: int,
  sendCount?: string,
  sendRoot?: string,
  mixHash?: string,
}

type evmTransactionInput = {
  from?: Address.t,
  to?: Address.t,
  gas?: bigint,
  gasPrice?: bigint,
  hash?: string,
  input?: string,
  nonce?: bigint,
  transactionIndex?: int,
  value?: bigint,
  // Signature fields - optional for ZKSync EIP-712 compatibility
  v?: string,
  r?: string,
  s?: string,
  yParity?: string,
  // EIP-1559 fields
  maxPriorityFeePerGas?: bigint,
  maxFeePerGas?: bigint,
  // EIP-4844 blob fields
  maxFeePerBlobGas?: bigint,
  blobVersionedHashes?: array<string>,
  // Receipt fields (from joined transaction receipts)
  cumulativeGasUsed?: bigint,
  effectiveGasPrice?: bigint,
  gasUsed?: bigint,
  contractAddress?: string,
  logsBloom?: string,
  @as("type")
  type_?: int,
  root?: string,
  status?: int,
  accessList?: JSON.t,
  // L2 specific fields (Optimism, Arbitrum, etc.)
  l1Fee?: bigint,
  l1GasPrice?: bigint,
  l1GasUsed?: bigint,
  l1FeeScalar?: float,
  gasUsedForL1?: bigint,
  authorizationList?: JSON.t,
}

type genericEvent<'params, 'block, 'transaction> = {
  contractName: string,
  eventName: string,
  params: 'params,
  chainId: int,
  srcAddress: Address.t,
  logIndex: int,
  transaction: 'transaction,
  block: 'block,
}

// Opaque internally — block-level values needed by the runtime
// (blockNumber, timestamp, blockHash) live on the item instead.
type event

// Opaque payload an item carries. A source builds an ecosystem-specific
// concrete payload (see `Evm.payload` / `Fuel.payload`) and erases it to this
// type; consumers never read it directly — the ecosystem converts it back to
// its own payload to produce the user-facing `event`, a logger, or a raw
// event. The concrete payload types deliberately live in the ecosystem
// modules, not here, and are distinct per ecosystem.
type eventPayload

// Generic access to the payload's `transaction`, written at batch prep for
// store-backed ecosystems (HyperSync) and present inline otherwise.
@get external getPayloadTransaction: eventPayload => Nullable.t<eventTransaction> = "transaction"
@set external setPayloadTransaction: (eventPayload, eventTransaction) => unit = "transaction"

// Generic access to the payload's `block`, written at batch prep for store-backed
// ecosystems (EVM HyperSync) and present inline otherwise.
@get external getPayloadBlock: eventPayload => Nullable.t<eventBlock> = "block"
@set external setPayloadBlock: (eventPayload, eventBlock) => unit = "block"

type genericLoaderArgs<'event, 'context> = {
  event: 'event,
  context: 'context,
}
type genericLoader<'args, 'loaderReturn> = 'args => promise<'loaderReturn>

type genericContractRegisterArgs<'event, 'context> = {
  event: 'event,
  context: 'context,
}
type genericContractRegister<'args> = 'args => promise<unit>

type contractRegisterContext
type contractRegisterArgs = genericContractRegisterArgs<event, contractRegisterContext>
type contractRegister = genericContractRegister<contractRegisterArgs>

type genericHandlerArgs<'event, 'context> = {
  event: 'event,
  context: 'context,
}
type genericHandler<'args> = 'args => promise<unit>

type entityHandlerContext<'entity> = {
  get: string => promise<option<'entity>>,
  getOrThrow: (string, ~message: string=?) => promise<'entity>,
  getOrCreate: 'entity => promise<'entity>,
  set: 'entity => unit,
  deleteUnsafe: string => unit,
}

type chainInfo = {
  id: int,
  // True once every chain has caught up to head/endBlock and entered real-time
  // indexing mode. False while any chain is still backfilling.
  isRealtime: bool,
}

type chains = dict<chainInfo>

type loaderReturn
type handlerContext = private {
  isPreload: bool,
  chain: chainInfo,
}
type handlerArgs = {
  event: event,
  context: handlerContext,
}
type handler = genericHandler<handlerArgs>

type genericHandlerWithLoader<'loader, 'handler, 'where> = {
  loader: 'loader,
  handler: 'handler,
  wildcard?: bool,
  where?: 'where,
}

// Recursive tuple/struct component metadata emitted by the CLI when an event
// param (or any nested field) is a Solidity struct. `name` is always non-empty —
// the CLI fills in `"0"`, `"1"`, ... for anonymous components in mixed-name
// tuples — so the runtime can always rebuild a keyed object.
type rec paramMeta = {
  name: string,
  abiType: string,
  indexed: bool,
  components?: array<paramMeta>,
}

// Fetch-state registry value for an indexed contract address.
// `effectiveStartBlock` is derived from the registration block and the
// contract's configured start block (see `FetchState.deriveEffectiveStartBlock`).
type indexingContract = {
  address: Address.t,
  contractName: string,
  registrationBlock: int,
  effectiveStartBlock: int,
}

// This is private so it's not manually constructed internally
// The idea is that it can only be coerced from fuel/evmEventConfig
// and it can include their fields. We prevent manual creation,
// so the fields are not overwritten and we can safely cast the type back to fuel/evmEventConfig
type eventConfig = private {
  id: string,
  name: string,
  contractName: string,
  isWildcard: bool,
  // Whether the event has an event filter which uses addresses
  filterByAddresses: bool,
  // Usually always false for wildcard events
  // But might be true for wildcard event with dynamic event filter by addresses
  dependsOnAddresses: bool,
  // Precompiled predicate (EVM only) for events that filter an indexed address
  // param by registered addresses. Given the decoded event and the log's block
  // number, drops an event whose param-address isn't registered at/before that
  // block — the param-level analogue of EventRouter's srcAddress
  // `effectiveStartBlock` check. Absent otherwise.
  clientAddressFilter?: (eventPayload, int, dict<indexingContract>) => bool,
  handler: option<handler>,
  contractRegister: option<contractRegister>,
  paramsRawEventSchema: S.schema<eventParams>,
  simulateParamsSchema: S.schema<eventParams>,
  startBlock: option<int>,
  // Field names selected for the chain's transaction-store materialisation
  // (camelCase, matching the ecosystem's `transactionFields`). Stored as a
  // string set so the shared mask logic is ecosystem-agnostic; sources recover
  // the typed view where they need it.
  selectedTransactionFields: Utils.Set.t<string>,
  // `selectedTransactionFields` precompiled to the transaction-store selection
  // bitmask (bit per ecosystem field code). Materialisation reads this per item
  // so each transaction decodes only the fields its event selected. `0.` when
  // nothing is selected or the ecosystem carries the transaction inline (Fuel).
  transactionFieldMask: float,
  // Selected block fields precompiled to the block-store selection bitmask (bit
  // per ecosystem field code). `0.` for ecosystems that carry the block inline
  // (RPC/Fuel/SVM). Even for store-backed events the always-included
  // number/timestamp/hash are stamped from the item, so this only drives whether
  // the store is consulted for further fields.
  blockFieldMask: float,
}

type fuelEventKind =
  | LogData({logId: string, decode: string => eventParams})
  | Mint
  | Burn
  | Transfer
  | Call
type fuelEventConfig = {
  ...eventConfig,
  kind: fuelEventKind,
}
type fuelContractConfig = {
  name: string,
  events: array<fuelEventConfig>,
}

type topicSelection = {
  topic0: array<EvmTypes.Hex.t>,
  topic1: array<EvmTypes.Hex.t>,
  topic2: array<EvmTypes.Hex.t>,
  topic3: array<EvmTypes.Hex.t>,
}

// Per-event, per-invocation arguments passed to a `where` callback. The
// concrete `chain` shape (which contract key it exposes) is generated per
// event in user-project codegen — here it's an open record so codegen'd
// types subtype-coerce into it cleanly.
type onEventWhereArgs<'chain> = {chain: 'chain}

type eventFilters =
  Static(array<topicSelection>) | Dynamic(array<Address.t> => array<topicSelection>)

type evmEventConfig = {
  ...eventConfig,
  getEventFiltersOrThrow: ChainMap.Chain.t => eventFilters,
  selectedBlockFields: Utils.Set.t<evmBlockField>,
  sighash: string,
  topicCount: int,
  paramsMetadata: array<paramMeta>,
}

// Shared formula for `eventConfig.dependsOnAddresses`. Kept here so
// `EventConfigBuilder.build{Evm,Fuel}EventConfig` and
// `HandlerLoader.applyRegistrations` stay in sync when handler state flips
// the value. Fuel events always have `filterByAddresses=false`, so callers
// there simply pass it through as `false`.
let dependsOnAddresses = (~isWildcard, ~filterByAddresses) => !isWildcard || filterByAddresses

type evmContractConfig = {
  name: string,
  abi: EvmTypes.Abi.t,
  events: array<evmEventConfig>,
}

type svmAccountFilter = {
  position: int,
  values: array<SvmTypes.Pubkey.t>,
}

/** AND-group: every entry must match the same instruction. */
type svmAccountFilterGroup = array<svmAccountFilter>

type svmInstructionEventConfig = {
  ...eventConfig,
  /** Block fields selected via `field_selection.block_fields` (the `slot`/`time`/
   `hash` trio is always included and excluded from this set). Drives the block
   query columns; precompiled to `blockFieldMask` for store materialisation. */
  selectedBlockFields: Utils.Set.t<svmBlockField>,
  /** Base58 Solana program id this instruction belongs to. */
  programId: SvmTypes.Pubkey.t,
  /** Hex-encoded discriminator. `None` matches every instruction in the program. */
  discriminator: option<string>,
  /** Length of the discriminator in bytes (0 / 1 / 2 / 4 / 8). Drives the
   `dN` selector at query time and the dispatch-key precomputation in the
   router. */
  discriminatorByteLen: int,
  includeLogs: bool,
  /** Disjunctive normal form: outer array is OR of AND-groups, inner array is
   AND across positions. Empty outer array means "no account filter". */
  accountFilters: array<svmAccountFilterGroup>,
  /** `None` matches both outer and inner (CPI-invoked) instructions. */
  isInner: option<bool>,
  /** Positional account names from the Borsh schema, in declared order.
   `[]` means no schema is attached for this instruction. */
  accounts: array<string>,
  /** Borsh args layout as `Vec<ArgDef>` JSON (see `human_config::svm::ArgDef`
   on the Rust side). `JSON.Null` means no schema is attached. */
  args: JSON.t,
  /** Program-level nominal-type registry (`BTreeMap<String, ArgType>` JSON).
   Duplicated on every event of the same program — the runtime dedups by
   `programId` when registering. `JSON.Null` when empty. */
  definedTypes: JSON.t,
}

type svmProgramConfig = {
  name: string,
  programId: SvmTypes.Pubkey.t,
  instructions: array<svmInstructionEventConfig>,
}

type indexingAddress = {
  address: Address.t,
  contractName: string,
  // Needed for rollback.
  // -1 for config addresses that shouldn't be rolled back.
  registrationBlock: int,
}

type dcs = array<indexingAddress>

// Duplicate the type from item
// to make item properly unboxed
type eventItem = private {
  kind: [#0],
  eventConfig: eventConfig,
  timestamp: int,
  chain: ChainMap.Chain.t,
  blockNumber: int,
  blockHash: string,
  logIndex: int,
  // Within-block transaction index — the key into the per-chain transaction
  // store. Unused (0) for ecosystems that carry the transaction inline (Fuel).
  transactionIndex: int,
  payload: eventPayload,
}

// Row shape for the `raw_events` table. Defined here (rather than in
// `InternalTable`) so the ecosystem's `toRawEvent` can reference it without
// pulling in `InternalTable`'s dependency on `Config`.
type rawEvent = {
  chain_id: int,
  event_id: bigint,
  event_name: string,
  contract_name: string,
  block_number: int,
  log_index: int,
  src_address: Address.t,
  block_hash: string,
  block_timestamp: int,
  block_fields: JSON.t,
  transaction_fields: JSON.t,
  params: JSON.t,
}

// Opaque type to support both EVM and other ecosystems
type blockEvent

type onBlockArgs = {
  slot?: int,
  block?: blockEvent,
  context: handlerContext,
}

type onBlockConfig = {
  // When there are multiple onBlock handlers per chain,
  // we want to use the order they are defined for sorting
  index: int,
  name: string,
  chainId: int,
  startBlock: option<int>,
  endBlock: option<int>,
  interval: int,
  handler: onBlockArgs => promise<unit>,
}

@tag("kind")
type item =
  | @as(0)
  Event({
      eventConfig: eventConfig,
      timestamp: int,
      chain: ChainMap.Chain.t,
      blockNumber: int,
      blockHash: string,
      logIndex: int,
      transactionIndex: int,
      payload: eventPayload,
    })
  | @as(1) Block({onBlockConfig: onBlockConfig, blockNumber: int, logIndex: int})

external castUnsafeEventItem: item => eventItem = "%identity"

@get
external getItemBlockNumber: item => int = "blockNumber"
@get
external getItemLogIndex: item => int = "logIndex"

let getItemChainId = item =>
  switch item {
  | Event({chain}) => chain->ChainMap.Chain.toChainId
  | Block({onBlockConfig: {chainId}}) => chainId
  }

@get
external getItemDcs: item => option<dcs> = "dcs"
@set
external setItemDcs: (item, dcs) => unit = "dcs"

type eventOptions<'where> = {
  wildcard?: bool,
  where?: 'where,
}

type fuelSupplyParams = {
  subId: string,
  amount: bigint,
}
let fuelSupplyParamsSchema = S.schema(s => {
  subId: s.matches(S.string),
  amount: s.matches(Utils.BigInt.schema),
})
type fuelTransferParams = {
  to: Address.t,
  assetId: string,
  amount: bigint,
}
let fuelTransferParamsSchema = S.schema(s => {
  to: s.matches(Address.schema),
  assetId: s.matches(S.string),
  amount: s.matches(Utils.BigInt.schema),
})

type entity = private {id: string}

// Per-entity storage resolved at parse time against the global storage
// config. Downstream PG/CH consumers just check the matching boolean.
type entityStorage = {
  postgres: bool,
  clickhouse: bool,
}

type genericEntityConfig<'entity> = {
  name: string,
  index: int,
  schema: S.t<'entity>,
  table: Table.table,
  storage: entityStorage,
}
type entityConfig = genericEntityConfig<entity>
external fromGenericEntityConfig: genericEntityConfig<'entity> => entityConfig = "%identity"

type effectInput
type effectOutput
type effectContext = private {mutable cache: bool}
type effectArgs = {
  input: effectInput,
  context: effectContext,
  cacheKey: string,
  // The processing checkpoint that referenced this effect; stamped on the
  // in-memory cache entry so it's evicted once the checkpoint commits.
  checkpointId: bigint,
}
type effectCacheItem = {id: string, output: effectOutput}
type effectCacheStorageMeta = {
  itemSchema: S.t<effectCacheItem>,
  outputSchema: S.t<effectOutput>,
  table: Table.table,
}
type rateLimitState = {
  callsPerDuration: int,
  durationMs: int,
  mutable availableCalls: int,
  mutable windowStartTime: float,
  mutable queueCount: int,
  mutable nextWindowPromise: option<promise<unit>>,
}
type effect = {
  name: string,
  handler: effectArgs => promise<effectOutput>,
  storageMeta: effectCacheStorageMeta,
  defaultShouldCache: bool,
  output: S.t<effectOutput>,
  input: S.t<effectInput>,
  // The number of functions that are currently running.
  mutable activeCallsCount: int,
  mutable prevCallStartTimerRef: Performance.timeRef,
  rateLimit: option<rateLimitState>,
}
let cacheTablePrefix = "envio_effect_"
let cacheOutputSchema = S.json(~validate=false)->(Utils.magic: S.t<JSON.t> => S.t<effectOutput>)
let makeCacheTable = (~effectName) => {
  Table.mkTable(
    cacheTablePrefix ++ effectName,
    ~fields=[
      Table.mkField("id", String, ~fieldSchema=S.string, ~isPrimaryKey=true),
      Table.mkField("output", Json, ~fieldSchema=cacheOutputSchema, ~isNullable=true),
    ],
  )
}

type noOnEventWhere

type checkpointId = bigint

// Assigned to changes loaded from the db, which never become history.
let loadedFromDbCheckpointId: checkpointId = 0n

// Committed checkpoint before any batch is written.
let initialCheckpointId: checkpointId = 0n

type reorgCheckpoint = {
  @as("id")
  checkpointId: bigint,
  @as("chain_id")
  chainId: int,
  @as("block_number")
  blockNumber: int,
  @as("block_hash")
  blockHash: string,
}
