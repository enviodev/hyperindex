type unchecksummedEthAddress = string

type t

type cfg = {
  url: string,
  bearer_token?: string,
  http_req_timeout_millis?: int,
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
    miner?: unchecksummedEthAddress,
    difficulty?: Ethers.BigInt.t, //nullable
    totalDifficulty?: Ethers.BigInt.t, //nullable
    extraData?: string,
    size?: Ethers.BigInt.t,
    gasLimit?: Ethers.BigInt.t,
    gasUsed?: Ethers.BigInt.t,
    timestamp?: int,
    uncles?: string, //nullable
    baseFeePerGas?: Ethers.BigInt.t, //nullable
  }

  //Note all fields marked as "nullable" are not explicitly null since
  //the are option fields and nulls will be deserialized to option when
  //in an optional field with spice
  type transactionData = {
    blockHash?: string,
    blockNumber?: int,
    from?: unchecksummedEthAddress, //nullable
    gas?: Ethers.BigInt.t,
    gasPrice?: Ethers.BigInt.t, //nullable
    hash?: string,
    input?: string,
    nonce?: int,
    to?: unchecksummedEthAddress, //nullable
    @as("transactionIndex") transactionIndex?: int,
    value?: Ethers.BigInt.t,
    v?: string, //nullable
    r?: string, //nullable
    s?: string, //nullable
    maxPriorityFeePerGas?: Ethers.BigInt.t, //nullable
    maxFeePerGas?: Ethers.BigInt.t, //nullable
    chainId?: int, //nullable
    cumulativeGasUsed?: Ethers.BigInt.t,
    effectiveGasPrice?: Ethers.BigInt.t,
    gasUsed?: Ethers.BigInt.t,
    contractAddress?: unchecksummedEthAddress, //nullable
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
    address?: unchecksummedEthAddress,
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
    events: array<event>,
    rollbackGuard: option<rollbackGuard>,
  }
}

module Internal = {
  type constructor
  @module("@envio-dev/hypersync-client") external constructor: constructor = "HypersyncClient"

  @send external make: (constructor, cfg) => t = "new"

  @send
  external sendEventsReq: (t, QueryTypes.postQueryBody) => promise<ResponseTypes.response> =
    "sendEventsReq"
}

let make = (cfg: cfg) => {
  open Internal

  let cfg_with_token = {...cfg, bearer_token: "3dc856dd-b0ea-494f-b27e-017b8b6b7e07"}

  constructor->make(cfg_with_token)
}

let sendEventsReq = Internal.sendEventsReq

module Decoder = {
  type abiMapping = Js.Dict.t<Ethers.abi>

  type constructor
  @module("@envio-dev/hypersync-client") external constructor: constructor = "Decoder"

  type t

  @send external new: (constructor, abiMapping) => t = "new"
  @send external enableChecksummedAddresses: t => unit = "enableChecksummedAddresses"

  let make = abiMapping => {
    let t = constructor->new(abiMapping)
    t->enableChecksummedAddresses
    t
  }
  /*
  Note! Usinging opaque definitions here since unboxed doesn't yet support bigint!

  type rec decodedSolType<'a> = {val: 'a}

  @unboxed
  type rec decodedRaw =
    | DecodedBool(bool)
    | DecodedStr(string)
    | DecodedNum(Js.Bigint.t)
    | DecodedVal(decodedSolType<decodedRaw>)
    | DecodedArr(array<decodedRaw>)

  @unboxed
  type rec decodedUnderlying =
    | Bool(bool)
    | Str(string)
    | Num(Js.Bigint.t)
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
*/

  type decodedRaw
  type decodedUnderlying
  /**
  See the commented code above. This should be possible with unboxed
  rescript types but since there is not support yet for bigint I've just
  copied the rescript generated code (using int instead of bigint) and swapped
  it out int for bigint. 
  */
  let toUnderlying: decodedRaw => decodedUnderlying = %raw(`
    function toUnderlying(_d) {
      while(true) {
        var d = _d;
        if (Array.isArray(d)) {
          return d.map(toUnderlying);
        }
        switch (typeof d) {
          case "boolean" :
              return d;
          case "string" :
              return d;
          case "bigint" :
              return d;
          case "object" :
              _d = d.val;
              continue ;
          default:
            throw new Error("Unsupported type encountered: " + typeof d);
        }
      };
    }
  `)

  type decodedEvent = {
    indexed: array<decodedRaw>,
    body: array<decodedRaw>,
  }

  @send
  external decodeEvents: (t, array<ResponseTypes.event>) => promise<array<option<decodedEvent>>> =
    "decodeEvents"
}
