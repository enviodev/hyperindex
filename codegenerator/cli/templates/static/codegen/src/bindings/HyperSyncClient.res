@spice
type unchecksummedEthAddress = string

type t

@spice
type cfg = {
  url: string,
  bearer_token?: string,
  http_req_timeout_millis?: int,
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
  @module("skar-client-node") external constructor: constructor = "SkarClient"

  @send external make: (constructor, Js.Json.t) => t = "new"

  @send external sendReq: (t, Js.Json.t) => promise<ResponseTypes.response> = "sendReq"
}

let make = (cfg: cfg) => {
  open Internal
  constructor->make(cfg->cfg_encode)
}

let sendReq = (self: t, req: HyperSyncJsonApi.QueryTypes.postQueryBody) => {
  self->Internal.sendReq(req->HyperSyncJsonApi.QueryTypes.postQueryBody_encode)
}
