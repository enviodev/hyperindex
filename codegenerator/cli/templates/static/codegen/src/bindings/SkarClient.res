// export class SkarClient {
//   static new(cfg: JsonValue): SkarClient
//   sendReq(query: JsonValue): Promise<QueryResponse>
// }

@spice
type unchecksummedEthAddress = string

type t

@spice
type cfg = {
  url: string,
  bearer_token?: string,
  http_req_timeout_millis?: int,
}

type transaction
type block

module ResponseTypes = {
  //Note all fields marked as "nullable" are not explicitly null since
  //the are option fields and nulls will be deserialized to option when
  //in an optional field with spice
  @spice
  type blockData = {
    number?: int,
    hash?: string,
    @spice.key("parent_hash") parentHash?: string,
    nonce?: int, //nullable
    @spice.key("sha3_uncles") sha3Uncles?: string,
    @spice.key("logs_bloom") logsBloom?: string,
    @spice.key("transactions_root") transactionsRoot?: string,
    @spice.key("state_root") stateRoot?: string,
    @spice.key("receipts_root") receiptsRoot?: string,
    miner?: unchecksummedEthAddress,
    difficulty?: Ethers.BigInt.t, //nullable
    @spice.key("total_difficulty") totalDifficulty?: Ethers.BigInt.t, //nullable
    @spice.key("extra_data") extraData?: string,
    size?: Ethers.BigInt.t,
    @spice.key("gas_limit") gasLimit?: Ethers.BigInt.t,
    @spice.key("gas_used") gasUsed?: Ethers.BigInt.t,
    timestamp?: int,
    @spice.key("unclus") uncles?: string, //nullable
    @spice.key("base_fee_per_gas") baseFeePerGas?: Ethers.BigInt.t, //nullable
  }

  //Note all fields marked as "nullable" are not explicitly null since
  //the are option fields and nulls will be deserialized to option when
  //in an optional field with spice
  @spice
  type transactionData = {
    @spice.key("block_hash") blockHash?: string,
    @spice.key("block_number") blockNumber?: int,
    from?: unchecksummedEthAddress, //nullable
    gas?: Ethers.BigInt.t,
    @spice.key("gas_price") gasPrice?: Ethers.BigInt.t, //nullable
    hash?: string,
    input?: string,
    nonce?: int,
    to?: unchecksummedEthAddress, //nullable
    @spice.key("transaction_index") transactionIndex?: int,
    value?: Ethers.BigInt.t,
    v?: string, //nullable
    r?: string, //nullable
    s?: string, //nullable
    @spice.key("max_priority_fee_per_gas") maxPriorityFeePerGas?: Ethers.BigInt.t, //nullable
    @spice.key("max_fee_per_gas") maxFeePerGas?: Ethers.BigInt.t, //nullable
    @spice.key("chain_id") chainId?: int, //nullable
    @spice.key("cumulative_gas_used") cumulativeGasUsed?: Ethers.BigInt.t,
    @spice.key("effective_gas_price") effectiveGasPrice?: Ethers.BigInt.t,
    @spice.key("gas_used") gasUsed?: Ethers.BigInt.t,
    @spice.key("contract_address") contractAddress?: unchecksummedEthAddress, //nullable
    @spice.key("logs_bloom") logsBoom?: string,
    @spice.key("type") type_?: int, //nullable
    @spice.key("root") root?: string, //nullable
    @spice.key("status") status?: int, //nullable
    @spice.key("sighash") sighash?: string, //nullable
  }

  //Note all fields marked as "nullable" are not explicitly null since
  //the are option fields and nulls will be deserialized to option when
  //in an optional field with spice
  @spice
  type logData = {
    removed?: bool, //nullable
    @spice.key("log_index") index?: int,
    @spice.key("transaction_index") transactionIndex?: int,
    @spice.key("transaction_hash") transactionHash?: string,
    @spice.key("block_hash") blockHash?: string,
    @spice.key("block_number") blockNumber?: int,
    address?: unchecksummedEthAddress,
    data?: string,
    topics?: array<Ethers.EventFilter.topic>, //nullable
  }

  @spice
  type data = {
    blocks?: array<blockData>,
    transactions?: array<transactionData>,
    logs?: array<logData>,
  }

  @spice
  type queryResponse = {
    data: array<data>,
    @spice.key("archive_height") archiveHeight: int,
    @spice.key("next_block") nextBlock: int,
    @spice.key("total_execution_time") totalTime: int,
  }

  @spice
  type heightResponse = {height: int}
}

type event = {
  transaction?: ResponseTypes.transactionData,
  block?: ResponseTypes.blockData,
  log: ResponseTypes.logData,
}

type response = {
  archiveHeight: int,
  nextBlock: int,
  totalExecutionTime: int,
  events: array<event>,
}

module Internal = {
  type constructor
  @module("skar-client-node") external constructor: constructor = "SkarClient"

  @send external make: (constructor, Js.Json.t) => t = "new"

  @send external sendReq: (t, Js.Json.t) => promise<response> = "sendReq"
}

let make = (cfg: cfg) => {
  open Internal
  constructor->make(cfg->cfg_encode)
}

let sendReq = (self: t, req: Skar.QueryTypes.postQueryBody) => {
  self->Internal.sendReq(req->Skar.QueryTypes.postQueryBody_encode)
}
