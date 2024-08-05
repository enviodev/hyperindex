type cfg = {
  url: string,
  bearerToken?: string,
  httpReqTimeoutMillis?: int,
  maxNumRetries?: int,
  retryBackoffMs?: int,
  retryBaseMs?: int,
  retryCeilingMs?: int,
  enableChecksumAddresses?: bool,
}

module QueryTypes = {
  type blockFieldOptions =
    | @as("number") Number
    | @as("hash") Hash
    | @as("parent_hash") ParentHash
    | @as("nonce") Nonce
    | @as("sha3_uncles") Sha3Uncles
    | @as("logs_bloom") LogsBloom
    | @as("transactions_root") TransactionsRoot
    | @as("state_root") StateRoot
    | @as("receipts_root") ReceiptsRoot
    | @as("miner") Miner
    | @as("difficulty") Difficulty
    | @as("total_difficulty") TotalDifficulty
    | @as("extra_data") ExtraData
    | @as("size") Size
    | @as("gas_limit") GasLimit
    | @as("gas_used") GasUsed
    | @as("timestamp") Timestamp
    | @as("uncles") Uncles
    | @as("base_fee_per_gas") BaseFeePerGas

  type blockFieldSelection = array<blockFieldOptions>

  type transactionFieldOptions =
    | @as("block_hash") BlockHash
    | @as("block_number") BlockNumber
    | @as("from") From
    | @as("gas") Gas
    | @as("gas_price") GasPrice
    | @as("hash") Hash
    | @as("input") Input
    | @as("nonce") Nonce
    | @as("to") To
    | @as("transaction_index") TransactionIndex
    | @as("value") Value
    | @as("v") V
    | @as("r") R
    | @as("s") S
    | @as("max_priority_fee_per_gas") MaxPriorityFeePerGas
    | @as("max_fee_per_gas") MaxFeePerGas
    | @as("chainId") ChainId
    | @as("cumulative_gas_used") CumulativeGasUsed
    | @as("effective_gas_price") EffectiveGasPrice
    | @as("gas_used") GasUsed
    | @as("contract_address") ContractAddress
    | @as("logs_bloom") LogsBloom
    | @as("type") Type
    | @as("root") Root
    | @as("status") Status
    | @as("sighash") Sighash

  type transactionFieldSelection = array<transactionFieldOptions>

  type logFieldOptions =
    | @as("removed") Removed
    | @as("log_index") LogIndex
    | @as("transaction_index") TransactionIndex
    | @as("transaction_hash") TransactionHash
    | @as("block_hash") BlockHash
    | @as("block_number") BlockNumber
    | @as("address") Address
    | @as("data") Data
    | @as("topic0") Topic0
    | @as("topic1") Topic1
    | @as("topic2") Topic2
    | @as("topic3") Topic3

  type logFieldSelection = array<logFieldOptions>

  type fieldSelection = {
    block?: blockFieldSelection,
    transaction?: transactionFieldSelection,
    log?: logFieldSelection,
  }

  type logParams = {
    address?: array<Ethers.ethAddress>,
    topics: array<array<Ethers.EventFilter.topic>>,
  }

  type transactionParams = {
    from?: array<Ethers.ethAddress>,
    @as("to")
    to_?: array<Ethers.ethAddress>,
    sighash?: array<string>,
  }

  type postQueryBody = {
    fromBlock: int,
    @as("toBlock") toBlockExclusive?: int,
    logs?: array<logParams>,
    transactions?: array<transactionParams>,
    fieldSelection: fieldSelection,
    maxNumLogs?: int,
  }
}

module ResponseTypes = {
  //Note all fields marked as "nullable" are not explicitly null since
  //the are option fields and nulls will be deserialized to option when
  //in an optional field with spice
  type blockData = {
    number?: int,
    hash?: string,
    parentHash?: string,
    nonce?: int, //nullable
    sha3Uncles?: string,
    logsBloom?: string,
    transactionsRoot?: string,
    stateRoot?: string,
    receiptsRoot?: string,
    miner?: Address.t,
    difficulty?: bigint, //nullable
    totalDifficulty?: bigint, //nullable
    extraData?: string,
    size?: bigint,
    gasLimit?: bigint,
    gasUsed?: bigint,
    timestamp?: int,
    uncles?: string, //nullable
    baseFeePerGas?: bigint, //nullable
  }

  //Note all fields marked as "nullable" are not explicitly null since
  //the are option fields and nulls will be deserialized to option when
  //in an optional field with spice
  type transactionData = {
    blockHash?: string,
    blockNumber?: int,
    from?: Address.t, //nullable
    gas?: bigint,
    gasPrice?: bigint, //nullable
    hash?: string,
    input?: string,
    nonce?: int,
    to?: Address.t, //nullable
    @as("transactionIndex") transactionIndex?: int,
    value?: bigint,
    v?: string, //nullable
    r?: string, //nullable
    s?: string, //nullable
    maxPriorityFeePerGas?: bigint, //nullable
    maxFeePerGas?: bigint, //nullable
    chainId?: int, //nullable
    cumulativeGasUsed?: bigint,
    effectiveGasPrice?: bigint,
    gasUsed?: bigint,
    contractAddress?: Address.t, //nullable
    logsBoom?: string,
    type_?: int, //nullable
    root?: string, //nullable
    status?: int, //nullable
    sighash?: string, //nullable
  }

  //Note all fields marked as "nullable" are not explicitly null since
  //the are option fields and nulls will be deserialized to option when
  //in an optional field with spice
  type logData = {
    removed?: bool, //nullable
    @as("logIndex") index?: int,
    transactionIndex?: int,
    transactionHash?: string,
    blockHash?: string,
    blockNumber?: int,
    address?: Address.t,
    data?: string,
    topics?: array<Js.Nullable.t<Ethers.EventFilter.topic>>, //nullable
  }

  type event = {
    transaction?: transactionData,
    block?: blockData,
    log: logData,
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

  type response = {
    //Archive Height is only None if height is 0
    archiveHeight: option<int>,
    nextBlock: int,
    totalExecutionTime: int,
    data: array<event>,
    rollbackGuard: option<rollbackGuard>,
  }
}

type query = QueryTypes.postQueryBody
type eventResponse = ResponseTypes.response

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

let defaultToken = "3dc856dd-b0ea-494f-b27e-017b8b6b7e07"
let make = (~url) =>
  new({
    url,
    enableChecksumAddresses: true,
    bearerToken: Env.envioApiToken->Belt.Option.getWithDefault(defaultToken),
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
