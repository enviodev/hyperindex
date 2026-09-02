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
  | @as("signature") Signature
  | @as("feePayer") FeePayer
  | @as("success") Success
  | @as("err") Err
  | @as("fee") Fee
  | @as("computeUnitsConsumed") ComputeUnitsConsumed
  | @as("accountKeys") AccountKeys
  | @as("recentBlockhash") RecentBlockhash
  | @as("version") Version
  | @as("allSignatures") AllSignatures
  | @as("accountActivities") AccountActivities

let allSvmTransactionFields: array<svmTransactionField> = [
  TransactionIndex,
  Signature,
  FeePayer,
  Success,
  Err,
  Fee,
  ComputeUnitsConsumed,
  AccountKeys,
  RecentBlockhash,
  Version,
  AllSignatures,
  AccountActivities,
]

// All SVM block fields. `slot` is always included (the item's key); the rest
// are selectable via handler `fields.block`.
type svmBlockField =
  | @as("slot") Slot
  | @as("time") Time
  | @as("hash") Hash
  | @as("height") Height
  | @as("parentSlot") ParentSlot
  | @as("parentHash") ParentHash

// Static sets of field names whose source schemas must be wrapped with S.nullable.
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
  chainId: ChainId.t,
  srcAddress: Address.t,
  logIndex: int,
  transaction: 'transaction,
  block: 'block,
}

// Opaque internally — the block number needed by the runtime lives on the
// item instead.
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

// Generic access to the payload's `block`: written/enriched at batch prep for
// store-backed ecosystems (EVM/SVM HyperSync) and present inline otherwise.
@get external getPayloadBlock: eventPayload => Nullable.t<eventBlock> = "block"
@set external setPayloadBlock: (eventPayload, eventBlock) => unit = "block"

// The log's emitting address (EVM/Fuel; the program id carries it for SVM).
@get external getPayloadSrcAddress: eventPayload => Address.t = "srcAddress"

// The decoded params, read by name for the address-valued ones a `where`
// filters on. Only those names are ever looked up, so the address type is
// accurate at every use site.
@get external getPayloadAddressParams: eventPayload => dict<Address.t> = "params"

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
  get: EntityId.t => promise<option<'entity>>,
  getOrThrow: (EntityId.t, ~message: string=?) => promise<'entity>,
  getOrCreate: 'entity => promise<'entity>,
  set: 'entity => unit,
  deleteUnsafe: EntityId.t => unit,
}

type chainInfo = {
  id: ChainId.t,
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

// What a single registration fetches and materialises. Field names are strings
// so every ecosystem shares one type — the typed field variants are strings at
// runtime. Always built through `makeFieldSelection`/`unionFieldSelection`
// below, so a set and its mask are never derived from different inputs. Unlike
// `eventConfig`, not `private` — that would block those two constructors too,
// since a private record can only be coerced from a distinct record type.
type fieldSelection = {
  blockFields: Utils.Set.t<string>,
  transactionFields: Utils.Set.t<string>,
  instructionFields: Utils.Set.t<string>,
  accountActivityFields: Utils.Set.t<string>,
  logFields: Utils.Set.t<string>,
  // The sets precompiled to the store selections `ChainState` materialises with.
  blockMask: float,
  transactionMask: float,
}

// `~blockMaskFn`/`~transactionMaskFn` are the ecosystem's `Evm`/`Svm`/`Fuel`
// mask functions, which the ecosystem modules pass in (they depend on this
// module, so it can't reach them).
let makeFieldSelection = (
  ~blockFields: Utils.Set.t<string>,
  ~transactionFields: Utils.Set.t<string>,
  ~instructionFields: Utils.Set.t<string>=Utils.Set.make(),
  ~accountActivityFields: Utils.Set.t<string>=Utils.Set.make(),
  ~logFields: Utils.Set.t<string>=Utils.Set.make(),
  ~blockMaskFn: Utils.Set.t<string> => float,
  ~transactionMaskFn: Utils.Set.t<string> => float,
): fieldSelection => {
  blockFields,
  transactionFields,
  instructionFields,
  accountActivityFields,
  logFields,
  blockMask: blockMaskFn(blockFields),
  transactionMask: transactionMaskFn(transactionFields),
}

// Two registrations merged into one dispatch off a single item, so it has to
// carry the union of what both callbacks read. Each callback's type only claims
// its own selection, so the extra fields are unread rather than unsound.
//
// The overwhelmingly common case is two registrations that never named fields
// inline and so share their event config's sets by reference — returning those
// unchanged keeps the merge allocation-free.
let unionFields = (a, b) => a === b ? a : a->Utils.Set.union(b)

let unionFieldSelection = (a: fieldSelection, b: fieldSelection): fieldSelection => {
  blockFields: unionFields(a.blockFields, b.blockFields),
  transactionFields: unionFields(a.transactionFields, b.transactionFields),
  instructionFields: unionFields(a.instructionFields, b.instructionFields),
  accountActivityFields: unionFields(a.accountActivityFields, b.accountActivityFields),
  logFields: unionFields(a.logFields, b.logFields),
  blockMask: FieldMask.orMask(a.blockMask, b.blockMask),
  transactionMask: FieldMask.orMask(a.transactionMask, b.transactionMask),
}

// Definition of an event/instruction we know how to decode: identity + decode
// schemas + chain-independent field selection. A pure function of the ABI +
// config, shared across chains. `private` so it can only be coerced from an
// ecosystem variant (fields never overwritten), which lets sources cast the
// base back down to evm/fuel/svm safely.
type eventConfig = private {
  id: string,
  name: string,
  contractName: string,
  paramsRawEventSchema: S.schema<eventParams>,
  simulateParamsSchema: S.schema<eventParams>,
  // The `config.yaml` selection, which every registration of this event
  // inherits unless it names its own fields inline. Held by reference, so two
  // un-customized registrations share one set — which is what keeps a merge
  // allocation-free and the per-source parser caches (keyed on set identity)
  // effective.
  fieldSelection: fieldSelection,
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

// A single topic position of a resolved `where`: either static pre-encoded
// values, or a marker for "the currently registered addresses of this
// contract", expanded to topic values when a source query is built.
type topicFilter =
  | Values(array<EvmTypes.Hex.t>)
  | ContractAddresses({contractName: string})

type resolvedTopicSelection = {
  topic0: array<EvmTypes.Hex.t>,
  topic1: topicFilter,
  topic2: topicFilter,
  topic3: topicFilter,
}

// The registered `where` fully resolved at registration time for one chain.
// `topicSelections` is in disjunctive normal form (outer array is OR);
// an empty array means the `where` returned `false` for this chain.
type resolvedWhere = {
  topicSelections: array<resolvedTopicSelection>,
  startBlock: option<int>,
}

// Per-event, per-invocation arguments passed to a `where` callback. The
// concrete `chain` shape (which contract key it exposes) is generated per
// event in user-project codegen — here it's an open record so codegen'd
// types subtype-coerce into it cleanly.
type onEventWhereArgs<'chain> = {chain: 'chain}

type evmEventConfig = {
  ...eventConfig,
  sighash: string,
  topicCount: int,
  paramsMetadata: array<paramMeta>,
}

// Shared formula for a registration's `dependsOnAddresses`. Kept here so the
// `EventConfigBuilder.build*OnEventRegistration` builders stay in sync. Fuel
// and SVM events always have `filterByAddresses=false`, so callers there pass
// it through as `false`.
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
  /** Base58 Solana program id this instruction belongs to. */
  programId: SvmTypes.Pubkey.t,
  /** Hex-encoded discriminator. `None` matches every instruction in the program. */
  discriminator: option<string>,
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

// Per-(event, chain) registration produced when user handler code registers an
// event (`onEvent`) or a dynamic contract registers. References its definition
// by value as `.eventConfig` and adds the handler binding plus the
// registration/`where`-derived fetch state. Not `private`: Fuel registrations
// add no ecosystem-specific fields (so the alias must stay directly
// constructable), and the ecosystem→base casts in sources are sound by
// ecosystem homogeneity — an EVM chain only ever holds
// `evmOnEventRegistration`s.
type onEventRegistration = {
  // Chain-scoped sequential index — the registration's position in the
  // chain's onEventRegistrations array, assigned when registration finishes
  // (-1 until then). Native-routed items reference their registration by this
  // index across the napi boundary; sources resolve it before creating an item.
  index: int,
  eventConfig: eventConfig,
  handler: option<handler>,
  contractRegister: option<contractRegister>,
  isWildcard: bool,
  // Whether the event has an event filter which uses addresses.
  filterByAddresses: bool,
  // Usually always false for wildcard events, but might be true for a wildcard
  // event with a dynamic event filter by addresses.
  dependsOnAddresses: bool,
  // Indexed address params this event filters on, in disjunctive normal form
  // (OR of AND-groups), from `where: {params: {to: chain.C.addresses}}`. Every
  // source applies this natively while routing; it's carried here for the
  // simulate source, which has no native query boundary. Absent otherwise.
  //
  // Keep it optional: with every field required, ReScript compiles a
  // `{...registration, ...}` spread into an explicit field-by-field copy, which
  // drops the ecosystem-only fields an `evmOnEventRegistration` carries.
  addressFilterParamGroups?: array<array<string>>,
  // Final start block: the contract/chain config value, overridden by a
  // `where.block.number._gte` when the registered `where` supplies one.
  startBlock: option<int>,
  // The `eventConfig` selection unless the registration passed an inline
  // `fields` option, which replaces it. Two registrations of one event can
  // select different fields, so this is per-registration rather than shared.
  fieldSelection: fieldSelection,
}

type evmOnEventRegistration = {
  ...onEventRegistration,
  resolvedWhere: resolvedWhere,
}

// Fuel registrations add no ecosystem-specific fetch state, so it's a bare
// alias of the base registration.
type fuelOnEventRegistration = onEventRegistration

type svmOnEventRegistration = {
  ...onEventRegistration,
  /** Disjunctive normal form: outer array is OR of AND-groups, inner array is
   AND across positions. Empty outer array means "no account filter". */
  accountFilters: array<svmAccountFilterGroup>,
  /** `None` matches both outer and inner (CPI-invoked) instructions. */
  isInner: option<bool>,
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

// Duplicate the type from item to keep item properly unboxed. Runtime event
// items carry the registration their source already resolved from the
// ChainState-owned registration array.
type eventItem = private {
  kind: [#0],
  onEventRegistration: onEventRegistration,
  chainId: ChainId.t,
  blockNumber: int,
  logIndex: int,
  orderPath?: array<int>,
  // Within-block transaction index — the key into the per-chain transaction
  // store. Unused (0) for ecosystems that carry the transaction inline (Fuel).
  transactionIndex: int,
  payload: eventPayload,
}

// Row shape for the `raw_events` table. Defined here (rather than in
// `InternalTable`) so the ecosystem's `toRawEvent` can reference it without
// pulling in `InternalTable`'s dependency on `Config`.
type rawEvent = {
  chain_id: ChainId.t,
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

type onBlockRegistration = {
  // When there are multiple onBlock handlers per chain,
  // we want to use the order they are defined for sorting
  index: int,
  name: string,
  chainId: ChainId.t,
  startBlock: option<int>,
  endBlock: option<int>,
  interval: int,
  handler: onBlockArgs => promise<unit>,
}

@tag("kind")
type item =
  | @as(0)
  Event({
      onEventRegistration: onEventRegistration,
      chainId: ChainId.t,
      blockNumber: int,
      logIndex: int,
      // Ordering tiebreak for ecosystems whose within-block order isn't a
      // scalar. SVM keys an instruction by `(transactionIndex, path)`: the
      // logIndex above is the transaction, this is its position in that
      // transaction's CPI tree. Absent on EVM and Fuel, whose log/receipt
      // index already totally orders a block.
      orderPath?: array<int>,
      transactionIndex: int,
      payload: eventPayload,
    })
  | @as(1) Block({onBlockRegistration: onBlockRegistration, blockNumber: int})

external castUnsafeEventItem: item => eventItem = "%identity"

@get
external getItemBlockNumber: item => int = "blockNumber"
// Only meaningful on an `Event`: a block item has no log index, and the buffer
// comparator reads this only after the kinds match.
@get
external getItemLogIndex: item => int = "logIndex"
@get
external getItemOrderPath: item => Nullable.t<array<int>> = "orderPath"
// The variant tag. Read directly so the comparator can order every event of a
// block ahead of that block's handlers without a `switch`.
@get
external getItemKind: item => int = "kind"

let getItemChainId = item =>
  switch item {
  | Event({chainId})
  | Block({onBlockRegistration: {chainId}}) => chainId
  }

// EVM `fields` bag. Parsed from the JS object as `unknown` at registration;
// this record exists so ReScript tests can construct a typed EVM selection.
type evmFieldsSelection = {
  block?: array<string>,
  transaction?: array<string>,
}

type eventOptions<'where> = {
  wildcard?: bool,
  where?: 'where,
  fields?: unknown,
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

// A data skipping index emitted into the history table DDL as
// `INDEX <name> <expr> TYPE <type> GRANULARITY <granularity>`.
type clickhouseSkippingIndex = {
  name: string,
  expr: string,
  @as("type")
  type_: string,
  granularity?: int,
}

// Raw ClickHouse expressions/field names from the entity's
// @storage(clickhouse: {...}) directive, applied to the history table DDL.
type clickhouseTableOptions = {
  partitionBy?: string,
  orderBy?: array<string>,
  ttl?: string,
  skippingIndexes?: array<clickhouseSkippingIndex>,
}

// Per-entity storage resolved at parse time against the global storage
// config. Downstream PG/CH consumers just check the matching boolean.
type entityStorage = {
  postgres: bool,
  clickhouse: bool,
  clickhouseOptions?: clickhouseTableOptions,
}

type genericEntityConfig<'entity> = {
  name: string,
  index: int,
  schema: S.t<'entity>,
  table: Table.table,
  storage: entityStorage,
  // Resolved by the CLI against the config's `defaultCrossChain` and the
  // entity's `@crossChain`. When false the table carries a chain-id column in
  // its primary key and every row belongs to exactly one chain.
  crossChain: bool,
  // `@internal` on the entity: stored and usable in handlers as normal, but
  // never exposed through the GraphQL API (no Hasura tracking).
  internal: bool,
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
}
type rateLimitOptions = {
  callsPerDuration: int,
  durationMs: int,
}
type effect = {
  name: string,
  handler: effectArgs => promise<effectOutput>,
  storageMeta: effectCacheStorageMeta,
  defaultShouldCache: bool,
  // When true a single cache is shared across every chain and the handler must
  // not read context.chain. When false the cache is isolated per chain and
  // context.chain.id is available. None means the effect didn't say, and the
  // config's `defaultCrossChain` decides.
  crossChain: option<bool>,
  output: S.t<effectOutput>,
  input: S.t<effectInput>,
  rateLimit: option<rateLimitOptions>,
}

// Whether some piece of data (currently an effect cache; entities in a future
// version) is shared across every chain or isolated to a single chain. Unboxed:
// `CrossChain` is the string "crossChain" and `Chain(id)` is the raw chain id,
// discriminated by runtime type.
@unboxed
type chainScope =
  | @as("crossChain") CrossChain
  | Chain(ChainId.t)

let chainScopeToString = scope =>
  switch scope {
  | CrossChain => "crossChain"
  | Chain(chainId) => chainId->ChainId.toString
  }

let chainScopeChainId = scope =>
  switch scope {
  | CrossChain => None
  | Chain(chainId) => Some(chainId)
  }

// A copy of the entity carrying the chain-id column a per-chain entity's row
// needs. Never mutates the handler's object, which stays in the in-memory table.
let stampChainId = (entity: entity, ~fieldName, ~chainId: ChainId.t): entity =>
  Utils.Dict.merge(
    entity->(Utils.magic: entity => dict<unknown>),
    Dict.fromArray([(fieldName, chainId->(Utils.magic: ChainId.t => unknown))]),
  )->(Utils.magic: dict<unknown> => entity)

let cacheTablePrefix = "envio_effect_"

// The single reversible mapping between an effect's (name, scope) and its
// canonical Postgres cache-table name and .envio/cache file path. Everything
// that needs a cache address goes through here instead of slicing prefixes.
//   CrossChain  ->  envio_effect_<name>        <name>.tsv
//   Chain(1->ChainId.fromInt)    ->  envio_1_effect_<name>      1/<name>.tsv
//   Chain(137->ChainId.fromInt)  ->  envio_137_effect_<name>    137/<name>.tsv
module EffectCache = {
  let toTableName = (~effectName, ~scope) =>
    switch scope {
    | CrossChain => cacheTablePrefix ++ effectName
    | Chain(chainId) => `envio_${chainId->ChainId.toString}_effect_${effectName}`
    }

  // Only accepts a canonical decimal chain id ("7", not "007" or "1foo") —
  // the schema's parser follows parseFloat semantics and accepts both.
  let parseChainId = str =>
    switch try Some(str->ChainId.normalizeOrThrow) catch {
    | _ => None
    } {
    | Some(chainId) if chainId->ChainId.toString === str => Some(chainId)
    | _ => None
    }

  let chainScopedRe = /^envio_([0-9]+)_effect_(.+)$/
  let crossChainRe = /^envio_effect_(.+)$/

  // Inverse of toTableName. Returns None for any table name that isn't a cache
  // table. Chain-scoped is tried first: the `_effect_` separator keeps effect
  // names that themselves start with digits unambiguous.
  let fromTableName = (tableName): option<(string, chainScope)> =>
    switch RegExp.exec(chainScopedRe, tableName) {
    | Some(result) =>
      switch (
        RegExp.Result.matches(result)->Array.get(0),
        RegExp.Result.matches(result)->Array.get(1),
      ) {
      | (Some(Some(chainIdStr)), Some(Some(effectName))) =>
        switch parseChainId(chainIdStr) {
        | Some(chainId) => Some((effectName, Chain(chainId)))
        | None => None
        }
      | _ => None
      }
    | None =>
      switch RegExp.exec(crossChainRe, tableName) {
      | Some(result) =>
        switch RegExp.Result.matches(result)->Array.get(0) {
        | Some(Some(effectName)) => Some((effectName, CrossChain))
        | _ => None
        }
      | None => None
      }
    }

  // Relative posix path within .envio/cache. Chain-scoped caches live one
  // directory level deep, named by chain id.
  let toCachePath = (~effectName, ~scope) =>
    switch scope {
    | CrossChain => effectName ++ ".tsv"
    | Chain(chainId) => `${chainId->ChainId.toString}/${effectName}.tsv`
    }
}

let cacheOutputSchema = S.json(~validate=false)->(Utils.magic: S.t<JSON.t> => S.t<effectOutput>)
let makeCacheTable = (~effectName, ~scope) => {
  Table.mkTable(
    EffectCache.toTableName(~effectName, ~scope),
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
  chainId: ChainId.t,
  @as("block_number")
  blockNumber: int,
  @as("block_hash")
  blockHash: string,
}
