@spice
type unchecksummedEthAddress = string

type t

type cfg = {
  url: string,
  bearer_token?: string,
  http_req_timeout_millis?: int,
}

module QueryTypes = {
  @spice
  type blockFieldOptions =
    | @spice.as("number") Number
    | @spice.as("hash") Hash
    | @spice.as("parent_hash") ParentHash
    | @spice.as("nonce") Nonce
    | @spice.as("sha3_uncles") Sha3Uncles
    | @spice.as("logs_bloom") LogsBloom
    | @spice.as("transactions_root") TransactionsRoot
    | @spice.as("state_root") StateRoot
    | @spice.as("receipts_root") ReceiptsRoot
    | @spice.as("miner") Miner
    | @spice.as("difficulty") Difficulty
    | @spice.as("total_difficulty") TotalDifficulty
    | @spice.as("extra_data") ExtraData
    | @spice.as("size") Size
    | @spice.as("gas_limit") GasLimit
    | @spice.as("gas_used") GasUsed
    | @spice.as("timestamp") Timestamp
    | @spice.as("uncles") Uncles
    | @spice.as("base_fee_per_gas") BaseFeePerGas

  @spice
  type blockFieldSelection = array<blockFieldOptions>

  @spice
  type transactionFieldOptions =
    | @spice.as("block_hash") BlockHash
    | @spice.as("block_number") BlockNumber
    | @spice.as("from") From
    | @spice.as("gas") Gas
    | @spice.as("gas_price") GasPrice
    | @spice.as("hash") Hash
    | @spice.as("input") Input
    | @spice.as("nonce") Nonce
    | @spice.as("to") To
    | @spice.as("transaction_index") TransactionIndex
    | @spice.as("value") Value
    | @spice.as("v") V
    | @spice.as("r") R
    | @spice.as("s") S
    | @spice.as("max_priority_fee_per_gas") MaxPriorityFeePerGas
    | @spice.as("max_fee_per_gas") MaxFeePerGas
    | @spice.as("chainId") ChainId
    | @spice.as("cumulative_gas_used") CumulativeGasUsed
    | @spice.as("effective_gas_price") EffectiveGasPrice
    | @spice.as("gas_used") GasUsed
    | @spice.as("contract_address") ContractAddress
    | @spice.as("logs_bloom") LogsBloom
    | @spice.as("type") Type
    | @spice.as("root") Root
    | @spice.as("status") Status
    | @spice.as("sighash") Sighash

  @spice
  type transactionFieldSelection = array<transactionFieldOptions>

  @spice
  type logFieldOptions =
    | @spice.as("removed") Removed
    | @spice.as("log_index") LogIndex
    | @spice.as("transaction_index") TransactionIndex
    | @spice.as("transaction_hash") TransactionHash
    | @spice.as("block_hash") BlockHash
    | @spice.as("block_number") BlockNumber
    | @spice.as("address") Address
    | @spice.as("data") Data
    | @spice.as("topic0") Topic0
    | @spice.as("topic1") Topic1
    | @spice.as("topic2") Topic2
    | @spice.as("topic3") Topic3

  @spice
  type logFieldSelection = array<logFieldOptions>

  @spice
  type fieldSelection = {
    block?: blockFieldSelection,
    transaction?: transactionFieldSelection,
    log?: logFieldSelection,
  }

  @spice
  type logParams = {
    address?: array<Ethers.ethAddress>,
    topics: array<array<Ethers.EventFilter.topic>>,
  }

  @spice
  type transactionParams = {
    from?: array<Ethers.ethAddress>,
    @spice.key("to")
    to_?: array<Ethers.ethAddress>,
    sighash?: array<string>,
  }

  @spice
  type postQueryBody = {
    fromBlock: int,
    @spice.key("toBlock") toBlockExclusive?: int,
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

  type response = {
    archiveHeight: int,
    nextBlock: int,
    totalExecutionTime: int,
    events: array<event>,
  }
}

module Internal = {
  type constructor
  @module("@envio-dev/hypersync-client") external constructor: constructor = "HypersyncClient"

  @send external make: (constructor, cfg) => t = "new"

  @send external sendEventsReq: (t, Js.Json.t) => promise<ResponseTypes.response> = "sendEventsReq"
}

let make = (cfg: cfg) => {
  open Internal

  let cfg_with_token = {...cfg, bearer_token: "3dc856dd-b0ea-494f-b27e-017b8b6b7e07"}

  constructor->make(cfg_with_token)
}

let sendEventsReq = async (self: t, req: QueryTypes.postQueryBody) => {
  let body = req->QueryTypes.postQueryBody_encode
  let res = await self->Internal.sendEventsReq(body)

  res
}

module Decoder = {
  type abiMapping = Js.Dict.t<Ethers.abi>

  type constructor
  @module("@envio-dev/hypersync-client") external constructor: constructor = "Decoder"

  type t

  @send external new: (constructor, abiMapping) => t = "new"

  let make = constructor->new

  type decodedSolType<'a> = {val: 'a}

  type decodedEvent<'a> = {
    indexed: array<decodedSolType<'a>>,
    body: array<decodedSolType<'a>>,
  }

  @send
  external decodeEvents: (
    t,
    array<ResponseTypes.event>,
  ) => promise<array<option<decodedEvent<'a>>>> = "decodeEvents"
}
