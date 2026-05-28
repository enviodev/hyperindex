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

  type accessList = {
    address?: Address.t,
    storageKeys?: array<string>,
  }

  let accessListSchema = S.object(s => {
    address: ?s.field("address", S.option(Address.schema)),
    storageKeys: ?s.field("storageKeys", S.option(S.array(S.string))),
  })

  type authorizationList = {
    chainId: bigint,
    address: Address.t,
    nonce: int,
    yParity: [#0 | #1],
    r: string,
    s: string,
  }

  let authorizationListSchema = S.object(s => {
    chainId: s.field("chainId", S.bigint),
    address: s.field("address", Address.schema),
    nonce: s.field("nonce", S.int),
    yParity: s.field("yParity", S.enum([#0, #1])),
    r: s.field("r", S.string),
    s: s.field("s", S.string),
  })

  type transaction = {
    blockHash?: string,
    blockNumber?: int,
    from?: string,
    gas?: bigint,
    gasPrice?: bigint,
    hash?: string,
    input?: string,
    nonce?: bigint,
    to?: string,
    transactionIndex?: int,
    value?: bigint,
    v?: string,
    r?: string,
    s?: string,
    yParity?: string,
    maxPriorityFeePerGas?: bigint,
    maxFeePerGas?: bigint,
    chainId?: int,
    accessList?: array<accessList>,
    maxFeePerBlobGas?: bigint,
    blobVersionedHashes?: array<string>,
    cumulativeGasUsed?: bigint,
    effectiveGasPrice?: bigint,
    gasUsed?: bigint,
    contractAddress?: string,
    logsBloom?: string,
    @as("type") type_?: int,
    root?: string,
    status?: int,
    l1Fee?: bigint,
    l1GasPrice?: bigint,
    l1GasUsed?: bigint,
    l1FeeScalar?: float,
    gasUsedForL1?: bigint,
    authorizationList?: array<authorizationList>,
  }

  type log = {
    removed?: bool,
    @as("logIndex") index?: int,
    transactionIndex?: int,
    transactionHash?: string,
    blockHash?: string,
    blockNumber?: int,
    address?: Address.t,
    data?: string,
    topics?: array<Nullable.t<EvmTypes.Hex.t>>,
  }

  type event = {
    transaction?: transaction,
    block?: block,
    log: log,
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

type queryResponseData = {
  blocks: array<ResponseTypes.block>,
  transactions: array<ResponseTypes.transaction>,
  logs: array<ResponseTypes.log>,
}

type queryResponse = {
  archiveHeight: option<int>,
  nextBlock: int,
  totalExecutionTime: int,
  data: queryResponseData,
  rollbackGuard: option<ResponseTypes.rollbackGuard>,
}

module Decoder = {
  type eventParamsInput = {
    sighash: string,
    topicCount: int,
    eventName: string,
    params: array<Internal.paramMeta>,
  }

  type tWithParams = {
    decodeLogs: array<ResponseTypes.event> => promise<array<Nullable.t<Internal.eventParams>>>,
  }

  @send
  external classFromParams: (
    Core.decoderCtor,
    array<eventParamsInput>,
    ~checksumAddresses: bool=?,
  ) => tWithParams = "fromParams"

  let fromParams = (eventParams, ~checksumAddresses=?) =>
    Core.getAddon().decoder->classFromParams(eventParams, ~checksumAddresses?)
}

module EventItems = {
  module Log = {
    /// Slim log shape produced by the Rust client. Address is pre-unwrapped
    /// (and checksummed when the config asks for it), topics are pre-filtered
    /// to non-null hex strings, and `data` is pre-encoded.
    type t = {
      logIndex: int,
      address: Address.t,
      data: string,
      topics: array<EvmTypes.Hex.t>,
    }
  }

  type item = {
    log: Log.t,
    block: ResponseTypes.block,
    transaction: ResponseTypes.transaction,
    /// `Null` when the log's topic0/topic-count didn't match any signature
    /// passed to the client constructor.
    params: Nullable.t<Internal.eventParams>,
  }

  type response = {
    archiveHeight: option<int>,
    nextBlock: int,
    items: array<item>,
    rollbackGuard: option<ResponseTypes.rollbackGuard>,
  }
}

type t = {
  get: (~query: query) => promise<queryResponse>,
  getEventItems: (
    ~query: query,
    ~nonOptionalBlockFieldNames: array<string>,
    ~nonOptionalTransactionFieldNames: array<string>,
  ) => promise<EventItems.response>,
}

@send
external classNew: (Core.hypersyncClientCtor, cfg, string, array<Decoder.eventParamsInput>) => t =
  "new"

let makeWithAgent = (cfg, ~userAgent, ~eventParams) =>
  Core.getAddon().hypersyncClient->classNew(cfg, userAgent, eventParams)

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
  ~maxNumRetries,
  ~eventParams=[],
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
      maxNumRetries,
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
