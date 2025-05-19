type cfg = {
  url?: string,
  bearerToken?: string,
  httpReqTimeoutMillis?: int,
  maxNumRetries?: int,
  retryBackoffMs?: int,
  retryBaseMs?: int,
  retryCeilingMs?: int,
  enableChecksumAddresses?: bool,
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
    | Kind
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

  type traceField =
    | From
    | To
    | CallType
    | Gas
    | Input
    | Init
    | Value
    | Author
    | RewardType
    | BlockHash
    | BlockNumber
    | Address
    | Code
    | GasUsed
    | Output
    | Subtraces
    | TraceAddress
    | TransactionHash
    | TransactionPosition
    | Kind
    | Error

  type fieldSelection = {
    block?: array<blockField>,
    transaction?: array<transactionField>,
    log?: array<logField>,
    trace?: array<traceField>,
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

  type logSelection = {
    /**
     * Address of the contract, any logs that has any of these addresses will be returned.
     * Empty means match all.
     */
    address?: array<Address.t>,
    /**
     * Topics to match, each member of the top level array is another array, if the nth topic matches any
     *  topic specified in topics[n] the log will be returned. Empty means match all.
     */
    topics: topicSelection,
  }

  let makeLogSelection = (~address, ~topics) => {address, topics}

  type transactionSelection = {
    /**
     * Address the transaction should originate from. If transaction.from matches any of these, the transaction
     *  will be returned. Keep in mind that this has an and relationship with to filter, so each transaction should
     *  match both of them. Empty means match all.
     */
    from?: array<Address.t>,
    /**
     * Address the transaction should go to. If transaction.to matches any of these, the transaction will
     *  be returned. Keep in mind that this has an and relationship with from filter, so each transaction should
     *  match both of them. Empty means match all.
     */
    @as("to")
    to_?: array<Address.t>,
    /** If first 4 bytes of transaction input matches any of these, transaction will be returned. Empty means match all. */
    sighash?: array<string>,
    /** If tx.status matches this it will be returned. */
    status?: int,
    /** If transaction.type matches any of these values, the transaction will be returned */
    kind?: array<int>,
    contractAddress?: array<Address.t>,
  }

  type traceSelection = {
    from?: array<Address.t>,
    @as("to") to_?: array<Address.t>,
    address?: array<Address.t>,
    callType?: array<string>,
    rewardType?: array<string>,
    kind?: array<string>,
    sighash?: array<string>,
  }

  type blockSelection = {
    /**
     * Hash of a block, any blocks that have one of these hashes will be returned.
     * Empty means match all.
     */
    hash?: array<string>,
    /**
     * Miner address of a block, any blocks that have one of these miners will be returned.
     * Empty means match all.
     */
    miner?: array<Address.t>,
  }

  type joinMode = | @as(0) Default | @as(1) JoinAll | @as(2) JoinNothing

  type query = {
    /** The block to start the query from */
    fromBlock: int,
    /**
     * The block to end the query at. If not specified, the query will go until the
     *  end of data. Exclusive, the returned range will be [from_block..to_block).
     *
     * The query will return before it reaches this target block if it hits the time limit
     *  configured on the server. The user should continue their query by putting the
     *  next_block field in the response into from_block field of their next query. This implements
     *  pagination.
     */
    @as("toBlock")
    toBlockExclusive?: int,
    /**
     * List of log selections, these have an or relationship between them, so the query will return logs
     * that match any of these selections.
     */
    logs?: array<logSelection>,
    /**
     * List of transaction selections, the query will return transactions that match any of these selections and
     *  it will return transactions that are related to the returned logs.
     */
    transactions?: array<transactionSelection>,
    /**
     * List of trace selections, the query will return traces that match any of these selections and
     *  it will re turn traces that are related to the returned logs.
     */
    traces?: array<traceSelection>,
    /** List of block selections, the query will return blocks that match any of these selections */
    blocks?: array<blockSelection>,
    /**
     * Field selection. The user can select which fields they are interested in, requesting less fields will improve
     *  query execution time and reduce the payload size so the user should always use a minimal number of fields.
     */
    fieldSelection: fieldSelection,
    /**
     * Maximum number of blocks that should be returned, the server might return more blocks than this number but
     *  it won't overshoot by too much.
     */
    maxNumBlocks?: int,
    /**
     * Maximum number of transactions that should be returned, the server might return more transactions than this number but
     *  it won't overshoot by too much.
     */
    maxNumTransactions?: int,
    /**
     * Maximum number of logs that should be returned, the server might return more logs than this number but
     *  it won't overshoot by too much.
     */
    maxNumLogs?: int,
    /**
     * Maximum number of traces that should be returned, the server might return more traces than this number but
     *  it won't overshoot by too much.
     */
    maxNumTraces?: int,
    /**
     * Selects join mode for the query,
     * Default: join in this order logs -> transactions -> traces -> blocks
     * JoinAll: join everything to everything. For example if logSelection matches log0, we get the
     * associated transaction of log0 and then we get associated logs of that transaction as well. Applites similarly
     * to blocks, traces.
     * JoinNothing: join nothing.
     */
    joinMode?: joinMode,
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

  @genType
  type accessList = {
    address?: Address.t,
    storageKeys?: array<string>,
  }

  let accessListSchema = S.object(s => {
    address: ?s.field("address", S.option(Address.schema)),
    storageKeys: ?s.field("storageKeys", S.option(S.array(S.string))),
  })

  @genType
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
    kind?: int,
    root?: string,
    status?: int,
    l1Fee?: bigint,
    l1GasPrice?: bigint,
    l1GasUsed?: bigint,
    l1FeeScalar?: int,
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
    topics?: array<Js.Nullable.t<EvmTypes.Hex.t>>,
  }

  type event = {
    transaction?: transaction,
    block?: block,
    log: log,
  }

  type rollbackGuard = {
    /** Block number of the last scanned block */
    blockNumber: int,
    /** Block timestamp of the last scanned block */
    timestamp: int,
    /** Block hash of the last scanned block */
    hash: string,
    /**
   * Block number of the first scanned block in memory.
   *
   * This might not be the first scanned block. It only includes blocks that are in memory (possible to be rolled back).
   */
    firstBlockNumber: int,
    /**
   * Parent hash of the first scanned block in memory.
   *
   * This might not be the first scanned block. It only includes blocks that are in memory (possible to be rolled back).
   */
    firstParentHash: string,
  }

  type eventResponse = {
    /** Current height of the source hypersync instance */
    archiveHeight: option<int>,
    /**
     * Next block to query for, the responses are paginated so,
     *  the caller should continue the query from this block if they
     *  didn't get responses up to the to_block they specified in the Query.
     */
    nextBlock: int,
    /** Total time it took the hypersync instance to execute the query. */
    totalExecutionTime: int,
    /** Response data */
    data: array<event>,
    /** Rollback guard, supposed to be used to detect rollbacks */
    rollbackGuard: option<rollbackGuard>,
  }
}

type query = QueryTypes.query
type eventResponse = ResponseTypes.eventResponse

//Todo, add bindings for these types
type streamConfig
type queryResponse
type queryResponseStream
type eventStream
type t = {
  getHeight: unit => promise<int>,
  collect: (~query: query, ~config: streamConfig) => promise<queryResponse>,
  collectEvents: (~query: query, ~config: streamConfig) => promise<eventResponse>,
  collectParquet: (~path: string, ~query: query, ~config: streamConfig) => promise<unit>,
  get: (~query: query) => promise<queryResponse>,
  getEvents: (~query: query) => promise<eventResponse>,
  stream: (~query: query, ~config: streamConfig) => promise<queryResponseStream>,
  streamEvents: (~query: query, ~config: streamConfig) => promise<eventStream>,
}

@module("@envio-dev/hypersync-client") @scope("HypersyncClient") external new: cfg => t = "new"

let make = (~url, ~apiToken, ~httpReqTimeoutMillis, ~maxNumRetries) =>
  new({
    url,
    enableChecksumAddresses: true,
    bearerToken: apiToken,
    httpReqTimeoutMillis,
    maxNumRetries,
  })

module Decoder = {
  type rec decodedSolType<'a> = {val: 'a}

  @unboxed
  type rec decodedRaw =
    | DecodedBool(bool)
    | DecodedStr(string)
    | DecodedNum(bigint)
    | DecodedVal(decodedSolType<decodedRaw>)
    | DecodedArr(array<decodedRaw>)

  @unboxed
  type rec decodedUnderlying =
    | Bool(bool)
    | Str(string)
    | Num(bigint)
    | Arr(array<decodedUnderlying>)

  let rec toUnderlying = (d: decodedRaw): decodedUnderlying => {
    switch d {
    | DecodedVal(v) => v.val->toUnderlying
    | DecodedBool(v) => Bool(v)
    | DecodedStr(v) => Str(v)
    | DecodedNum(v) => Num(v)
    | DecodedArr(v) => v->Belt.Array.map(toUnderlying)->Arr
    }
  }

  type decodedEvent = {
    indexed: array<decodedRaw>,
    body: array<decodedRaw>,
  }

  type log
  type t = {
    enableChecksummedAddresses: unit => unit,
    disableChecksummedAddresses: unit => unit,
    decodeLogs: array<log> => promise<array<Js.Nullable.t<decodedEvent>>>,
    decodeLogsSync: array<log> => array<Js.Nullable.t<decodedEvent>>,
    decodeEvents: array<ResponseTypes.event> => promise<array<Js.Nullable.t<decodedEvent>>>,
    decodeEventsSync: array<ResponseTypes.event> => array<Js.Nullable.t<decodedEvent>>,
  }

  @module("@envio-dev/hypersync-client") @scope("Decoder")
  external fromSignatures: array<string> => t = "fromSignatures"
}
