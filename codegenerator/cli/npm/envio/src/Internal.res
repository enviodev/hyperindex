type eventParams
type eventBlock
type eventTransaction

@genType
type genericEvent<'params, 'block, 'transaction> = {
  params: 'params,
  chainId: int,
  srcAddress: Address.t,
  logIndex: int,
  transaction: 'transaction,
  block: 'block,
}

type event = genericEvent<eventParams, eventBlock, eventTransaction>

external fromGenericEvent: genericEvent<'a, 'b, 'c> => event = "%identity"

@genType
type genericLoaderArgs<'event, 'context> = {
  event: 'event,
  context: 'context,
}
@genType
type genericLoader<'args, 'loaderReturn> = 'args => promise<'loaderReturn>

@genType
type genericContractRegisterArgs<'event, 'context> = {
  event: 'event,
  context: 'context,
}
@genType.import(("./Types.ts", "GenericContractRegister"))
type genericContractRegister<'args> = 'args => promise<unit>

type contractRegisterContext
type contractRegisterArgs = genericContractRegisterArgs<event, contractRegisterContext>
type contractRegister = genericContractRegister<contractRegisterArgs>

@genType
type genericHandlerArgs<'event, 'context> = {
  event: 'event,
  context: 'context,
}
@genType
type genericHandler<'args> = 'args => promise<unit>

@genType
type entityHandlerContext<'entity> = {
  get: string => promise<option<'entity>>,
  getOrThrow: (string, ~message: string=?) => promise<'entity>,
  getOrCreate: 'entity => promise<'entity>,
  set: 'entity => unit,
  deleteUnsafe: string => unit,
}

type chainInfo = {
  id: int,
  // true when the chain has completed initial sync and is processing live events
  // false during historical synchronization
  isLive: bool,
}

type chains = dict<chainInfo>

type loaderReturn
type handlerContext = private {
  isPreload: bool,
  chains: chains,
  chain: chainInfo,
}
type handlerArgs = {
  event: event,
  context: handlerContext,
}
type handler = genericHandler<handlerArgs>

@genType
type genericHandlerWithLoader<'loader, 'handler, 'eventFilters> = {
  loader: 'loader,
  handler: 'handler,
  wildcard?: bool,
  eventFilters?: 'eventFilters,
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
  handler: option<handler>,
  contractRegister: option<contractRegister>,
  paramsRawEventSchema: S.schema<eventParams>,
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

type eventFiltersArgs = {chainId: int, addresses: array<Address.t>}

type eventFilters =
  Static(array<topicSelection>) | Dynamic(array<Address.t> => array<topicSelection>)

type evmEventConfig = {
  ...eventConfig,
  getEventFiltersOrThrow: ChainMap.Chain.t => eventFilters,
  blockSchema: S.schema<eventBlock>,
  transactionSchema: S.schema<eventTransaction>,
  convertHyperSyncEventArgs: HyperSyncClient.Decoder.decodedEvent => eventParams,
}
type evmContractConfig = {
  name: string,
  abi: EvmTypes.Abi.t,
  events: array<evmEventConfig>,
}

type indexingContract = {
  address: Address.t,
  contractName: string,
  startBlock: int,
  // Needed for rollback
  // If not set, assume the contract comes from config
  // and shouldn't be rolled back
  registrationBlock: option<int>,
}

type dcs = array<indexingContract>

// Duplicate the type from item
// to make item properly unboxed
type eventItem = private {
  kind: [#0],
  eventConfig: eventConfig,
  timestamp: int,
  chain: ChainMap.Chain.t,
  blockNumber: int,
  logIndex: int,
  event: event,
}

// Opaque type to support both EVM and other ecosystems
type blockEvent

type onBlockArgs = {
  block: blockEvent,
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
      logIndex: int,
      event: event,
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

@genType
type eventOptions<'eventFilters> = {
  wildcard?: bool,
  eventFilters?: 'eventFilters,
}

@genType
type fuelSupplyParams = {
  subId: string,
  amount: bigint,
}
let fuelSupplyParamsSchema = S.schema(s => {
  subId: s.matches(S.string),
  amount: s.matches(BigInt.schema),
})
@genType
type fuelTransferParams = {
  to: Address.t,
  assetId: string,
  amount: bigint,
}
let fuelTransferParamsSchema = S.schema(s => {
  to: s.matches(Address.schema),
  assetId: s.matches(S.string),
  amount: s.matches(BigInt.schema),
})

type entity = private {id: string}
type clickHouseSetUpdatesCache = {
  tableName: string,
  convertOrThrow: Change.t<entity> => Js.Json.t,
}
type genericEntityConfig<'entity> = {
  name: string,
  index: int,
  schema: S.t<'entity>,
  rowsSchema: S.t<array<'entity>>,
  table: Table.table,
  mutable clickHouseSetUpdatesCache?: clickHouseSetUpdatesCache,
  mutable pgEntityHistoryCache?: EntityHistory.pgEntityHistory<'entity>,
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
  mutable prevCallStartTimerRef: Hrtime.timeRef,
  rateLimit: option<rateLimitState>,
}
let cacheTablePrefix = "envio_effect_"
let cacheOutputSchema = S.json(~validate=false)->(Utils.magic: S.t<Js.Json.t> => S.t<effectOutput>)
let effectCacheItemRowsSchema = S.array(
  S.schema(s => {id: s.matches(S.string), output: s.matches(cacheOutputSchema)}),
)
let makeCacheTable = (~effectName) => {
  Table.mkTable(
    cacheTablePrefix ++ effectName,
    ~fields=[
      Table.mkField("id", String, ~fieldSchema=S.string, ~isPrimaryKey=true),
      Table.mkField("output", Json, ~fieldSchema=cacheOutputSchema, ~isNullable=true),
    ],
  )
}

@genType.import(("./Types.ts", "Invalid"))
type noEventFilters

type checkpointId = float

type reorgCheckpoint = {
  @as("id")
  checkpointId: float,
  @as("chain_id")
  chainId: int,
  @as("block_number")
  blockNumber: int,
  @as("block_hash")
  blockHash: string,
}

type inMemoryStoreEntityUpdate<'entity> = {
  latestChange: Change.t<'entity>,
  history: array<Change.t<'entity>>,
  // In the event of a rollback, some entity updates may have been
  // been affected by a rollback diff. If there was no rollback diff
  // this will always be false.
  // If there was a rollback diff, this will be false in the case of a
  // new entity update (where entity affected is not present in the diff) b
  // but true if the update is related to an entity that is
  // currently present in the diff
  containsRollbackDiffChange: bool,
}

@unboxed
type inMemoryStoreEntityStatus<'entity> =
  | Updated(inMemoryStoreEntityUpdate<'entity>)
  | Loaded // This means there is no change from the db.
