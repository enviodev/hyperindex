/** Determines query serialization format for HTTP requests. */
type serializationFormat =
  // Use JSON serialization (default)
  | Json
  // Use Cap'n Proto binary serialization
  | CapnProto

let serializationFormatSchema = S.enum([Json, CapnProto])

type cfg = {
  /** HyperSync server URL. */
  url: string,
  /** HyperSync server api token. */
  apiToken: string,
  /** Milliseconds to wait for a response before timing out. Default: 30000. */
  httpReqTimeoutMillis?: int,
  /** Number of retries to attempt before returning error. Default: 12. */
  maxNumRetries?: int,
  /** Milliseconds that would be used for retry backoff increasing. Default: 500. */
  retryBackoffMs?: int,
  /** Initial wait time for request backoff. Default: 200. */
  retryBaseMs?: int,
  /** Ceiling time for request backoff. Default: 5000. */
  retryCeilingMs?: int,
  /** Enable checksum addresses in responses. */
  enableChecksumAddresses?: bool,
  /** Query serialization format to use for HTTP requests. Default: Json. */
  serializationFormat?: serializationFormat,
  /** Whether to use query caching when using CapnProto serialization format. */
  enableQueryCaching?: bool,
  logLevel?: string,
}

module QueryTypes = {
  type blockField =
    | Number
    | Hash
    | ParentHash
    | Nonce
    | Sha3Uncles
    | LogsBloom
    | TransactionsRoot
    | StateRoot
    | ReceiptsRoot
    | Miner
    | Difficulty
    | TotalDifficulty
    | ExtraData
    | Size
    | GasLimit
    | GasUsed
    | Timestamp
    | Uncles
    | BaseFeePerGas
    | BlobGasUsed
    | ExcessBlobGas
    | ParentBeaconBlockRoot
    | WithdrawalsRoot
    | Withdrawals
    | L1BlockNumber
    | SendCount
    | SendRoot
    | MixHash

  type transactionField =
    | BlockHash
    | BlockNumber
    | From
    | Gas
    | GasPrice
    | Hash
    | Input
    | Nonce
    | To
    | TransactionIndex
    | Value
    | V
    | R
    | S
    | YParity
    | MaxPriorityFeePerGas
    | MaxFeePerGas
    | ChainId
    | AccessList
    | MaxFeePerBlobGas
    | BlobVersionedHashes
    | CumulativeGasUsed
    | EffectiveGasPrice
    | GasUsed
    | ContractAddress
    | LogsBloom
    | Type
    | Root
    | Status
    | L1Fee
    | L1GasPrice
    | L1GasUsed
    | L1FeeScalar
    | GasUsedForL1
    | AuthorizationList

  type logField =
    | Removed
    | LogIndex
    | TransactionIndex
    | TransactionHash
    | BlockHash
    | BlockNumber
    | Address
    | Data
    | Topic0
    | Topic1
    | Topic2
    | Topic3

  type fieldSelection = {
    block?: array<blockField>,
    transaction?: array<transactionField>,
    log?: array<logField>,
  }
  type topicFilter = array<EvmTypes.Hex.t>
  type topic0 = topicFilter
  type topic1 = topicFilter
  type topic2 = topicFilter
  type topic3 = topicFilter
  type topicSelection = (topic0, topic1, topic2, topic3)
  let makeTopicSelection = (~topic0=[], ~topic1=[], ~topic2=[], ~topic3=[]) => (
    topic0,
    topic1,
    topic2,
    topic3,
  )

  type logFilter = {
    address?: array<Address.t>,
    topics: topicSelection,
  }

  let makeLogSelection = (~address, ~topics) => {address, topics}

  type transactionFilter = {
    from?: array<Address.t>,
    @as("to") to_?: array<Address.t>,
    sighash?: array<string>,
    status?: int,
    @as("type") type_?: array<int>,
    contractAddress?: array<Address.t>,
  }

  type blockSelection = {
    hash?: array<string>,
    miner?: array<Address.t>,
  }

  type joinMode = | @as(0) Default | @as(1) JoinAll | @as(2) JoinNothing

  type query = {
    fromBlock: int,
    @as("toBlock") toBlockExclusive?: int,
    logs?: array<logFilter>,
    transactions?: array<transactionFilter>,
    blocks?: array<blockSelection>,
    fieldSelection: fieldSelection,
    maxNumBlocks?: int,
    maxNumTransactions?: int,
    maxNumLogs?: int,
    joinMode?: joinMode,
    includeAllBlocks?: bool,
  }
}

module ResponseTypes = {
  type withdrawal = {
    index?: string,
    validatorIndex?: string,
    address?: Address.t,
    amount?: string,
  }

  type block = {
    number?: int,
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
    timestamp?: int,
    uncles?: array<string>,
    baseFeePerGas?: bigint,
    blobGasUsed?: bigint,
    excessBlobGas?: bigint,
    parentBeaconBlockRoot?: string,
    withdrawalsRoot?: string,
    withdrawals?: array<withdrawal>,
    l1BlockNumber?: int,
    sendCount?: string,
    sendRoot?: string,
    mixHash?: string,
  }

  type rollbackGuard = {
    blockNumber: int,
    timestamp: int,
    hash: string,
    firstBlockNumber: int,
    firstParentHash: string,
  }
}

type query = QueryTypes.query

type queryResponseData = {blocks: array<ResponseTypes.block>}

type queryResponse = {
  archiveHeight: option<int>,
  nextBlock: int,
  totalExecutionTime: int,
  data: queryResponseData,
  rollbackGuard: option<ResponseTypes.rollbackGuard>,
}

module Registration = {
  // One topic position of the resolved `where`: static topic values, or
  // `None` — the "currently registered addresses of this contract" marker,
  // expanded to padded address topics when Rust builds a query.
  type topicFilterInput = option<array<string>>

  type topicSelectionInput = {
    topic0: array<string>,
    topic1: topicFilterInput,
    topic2: topicFilterInput,
    topic3: topicFilterInput,
  }

  // The full per-(event, chain) registration passed to the Rust clients at
  // construction: decode metadata, routing identity, and the fetch state
  // queries are built from.
  type input = {
    // Chain-scoped sequential registration index, echoed back on routed items.
    index: int,
    sighash: string,
    topicCount: int,
    eventName: string,
    contractName: string,
    isWildcard: bool,
    dependsOnAddresses: bool,
    params: array<Internal.paramMeta>,
    topicSelections: array<topicSelectionInput>,
    // Capitalized field names matching the Rust BlockField/TransactionField
    // string enums.
    blockFields: array<string>,
    transactionFields: array<string>,
  }

  let toTopicFilterInput = (filter: Internal.topicFilter): topicFilterInput =>
    switch filter {
    | Values(values) => Some(values->EvmTypes.Hex.toStrings)
    | ContractAddresses(_) => None
    }

  let fromOnEventRegistrations = (
    onEventRegistrations: array<Internal.evmOnEventRegistration>,
  ): array<input> => {
    onEventRegistrations->Array.map(reg => {
      let event = reg.eventConfig->(Utils.magic: Internal.eventConfig => Internal.evmEventConfig)
      {
        index: reg.index,
        sighash: event.sighash,
        topicCount: event.topicCount,
        eventName: event.name,
        contractName: event.contractName,
        isWildcard: reg.isWildcard,
        dependsOnAddresses: reg.dependsOnAddresses,
        params: event.paramsMetadata,
        topicSelections: reg.resolvedWhere.topicSelections->Array.map((ts): topicSelectionInput => {
          topic0: ts.topic0->EvmTypes.Hex.toStrings,
          topic1: ts.topic1->toTopicFilterInput,
          topic2: ts.topic2->toTopicFilterInput,
          topic3: ts.topic3->toTopicFilterInput,
        }),
        // Capitalized to match the Rust BlockField/TransactionField string
        // enums.
        blockFields: event.selectedBlockFields
        ->Utils.Set.toArray
        ->Array.map(name => (name :> string)->Utils.String.capitalize),
        transactionFields: event.selectedTransactionFields
        ->Utils.Set.toArray
        ->Array.map(name => (name :> string)->Utils.String.capitalize),
      }
    })
  }
}

module EventItems = {
  // The whole per-query input: block range, the partition's registration
  // selection (by id), and its current addresses. Log selections, field
  // selection, and the routing index are derived on the Rust side.
  type query = {
    fromBlock: int,
    // Inclusive; None queries to the end of available data.
    toBlock: option<int>,
    maxNumLogs: int,
    registrationIndexes: array<int>,
    addressesByContractName: dict<array<Address.t>>,
  }

  type item = {
    logIndex: int,
    srcAddress: Address.t,
    // Number of the block this log belongs to; the block itself is resolved from
    // `response.blocks`, deduplicated across items sharing a block.
    blockNumber: int,
    // Key (with the block number) into the transaction store; the transaction
    // is resolved from the store on demand.
    transactionIndex: int,
    // The registration this log routed to, by chain-scoped index. Logs that
    // route to no registration never cross the boundary.
    onEventRegistrationIndex: int,
    params: Internal.eventParams,
  }

  // The always-needed block fields, one per block number. The block's remaining
  // fields live raw in the block store and are materialised on demand.
  type blockHeader = {
    number: int,
    timestamp: int,
    hash: string,
  }

  type response = {
    archiveHeight: option<int>,
    nextBlock: int,
    // One header per block number referenced by `items`.
    blocks: array<blockHeader>,
    items: array<item>,
    rollbackGuard: option<ResponseTypes.rollbackGuard>,
  }
}

type t = {
  get: (~query: query) => promise<queryResponse>,
  // Returns the response plus page stores owning this page's raw transactions
  // and blocks.
  getEventItems: (
    ~query: EventItems.query,
  ) => promise<(EventItems.response, TransactionStore.t, BlockStore.t)>,
  getHeight: unit => promise<int>,
}

@send
external classNew: (Core.evmHypersyncClientCtor, cfg, string, array<Registration.input>) => t =
  "new"

let makeWithAgent = (cfg, ~userAgent, ~eventRegistrations) =>
  Core.getAddon().evmHypersyncClient->classNew(cfg, userAgent, eventRegistrations)

type logLevel = [#trace | #debug | #info | #warn | #error]
let logLevelSchema: S.t<logLevel> = S.enum([#trace, #debug, #info, #warn, #error])

let logLevelToString = (level: logLevel) =>
  switch level {
  | #trace => "trace"
  | #debug => "debug"
  | #info => "info"
  | #warn => "warn"
  | #error => "error"
  }

let make = (
  ~url,
  ~apiToken,
  ~httpReqTimeoutMillis,
  ~eventRegistrations,
  ~enableChecksumAddresses=true,
  ~serializationFormat=?,
  ~enableQueryCaching=?,
  ~retryBaseMs=?,
  ~retryBackoffMs=?,
  ~retryCeilingMs=?,
  ~logLevel=#info,
) => {
  let envioVersion = Utils.EnvioPackage.value.version
  makeWithAgent(
    {
      url,
      enableChecksumAddresses,
      apiToken,
      httpReqTimeoutMillis,
      // Retries are handled internally by the indexer, not the binary client
      maxNumRetries: 0,
      ?serializationFormat,
      ?enableQueryCaching,
      ?retryBaseMs,
      ?retryBackoffMs,
      ?retryCeilingMs,
      logLevel: logLevelToString(logLevel),
    },
    ~userAgent=`hyperindex/${envioVersion}`,
    ~eventRegistrations,
  )
}
