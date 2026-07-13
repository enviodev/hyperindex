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
  type rollbackGuard = {
    blockNumber: int,
    timestamp: int,
    hash: string,
    firstBlockNumber: int,
    firstParentHash: string,
  }
}

type query = QueryTypes.query

module Decoder = {
  type eventParamsInput = {
    sighash: string,
    topicCount: int,
    eventName: string,
    contractName: string,
    params: array<Internal.paramMeta>,
  }
}

module EventItems = {
  type item = {
    logIndex: int,
    srcAddress: Address.t,
    topic0: EvmTypes.Hex.t,
    topicCount: int,
    // Number of the block this log belongs to; the block itself is resolved from
    // `response.blocks`, deduplicated across items sharing a block.
    blockNumber: int,
    // Key (with the block number) into the transaction store; the transaction
    // is resolved from the store on demand.
    transactionIndex: int,
    params: Nullable.t<dict<Internal.eventParams>>,
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
  // Block-hash query construction and pagination live in Rust; only the
  // aggregate response store crosses the boundary.
  getBlockHashes: (
    ~blockNumbers: array<int>,
  ) => promise<(BlockStore.t, array<Source.requestStat>)>,
  // Returns the response plus page stores owning this page's raw transactions
  // and blocks.
  getEventItems: (
    ~query: query,
  ) => promise<(EventItems.response, TransactionStore.t, BlockStore.t)>,
  getHeight: unit => promise<int>,
}

@send
external classNew: (
  Core.evmHypersyncClientCtor,
  cfg,
  string,
  array<Decoder.eventParamsInput>,
) => t = "new"

let makeWithAgent = (cfg, ~userAgent, ~eventParams) =>
  Core.getAddon().evmHypersyncClient->classNew(cfg, userAgent, eventParams)

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
  ~eventParams,
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
    ~eventParams,
  )
}
