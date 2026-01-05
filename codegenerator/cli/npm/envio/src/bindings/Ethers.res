type txHash = string

module Constants = {
  @module("ethers") @scope("ethers") external zeroHash: string = "ZeroHash"
  @module("ethers") @scope("ethers") external zeroAddress: Address.t = "ZeroAddress"
}

module Filter = {
  type t
}

module CombinedFilter = {
  type combinedFilterRecord = {
    address?: array<Address.t>,
    //The second element of the tuple is the
    topics: Rpc.GetLogs.topicQuery,
    fromBlock: int,
    toBlock: int,
  }

  let toFilter = (combinedFilter: combinedFilterRecord): Filter.t => combinedFilter->Utils.magic
}

type log = {
  blockNumber: int,
  blockHash: string,
  removed: option<bool>,
  //Note: this is the index of the log in the transaction and should be used whenever we use "logIndex"
  address: Address.t,
  data: string,
  topics: array<EvmTypes.Hex.t>,
  transactionHash: txHash,
  transactionIndex: int,
  //Note: this logIndex is the index of the log in the block, not the transaction
  @as("index") logIndex: int,
}

type transaction

type minimumParseableLogData = {topics: array<EvmTypes.Hex.t>, data: string}

//Can safely convert from log to minimumParseableLogData since it contains
//both data points required
let logToMinimumParseableLogData: log => minimumParseableLogData = Utils.magic

type logDescription<'a> = {
  args: 'a,
  name: string,
  signature: string,
  topic: string,
}

module Network = {
  type t

  @module("ethers") @new
  external make: (~name: string, ~chainId: int) => t = "Network"

  @module("ethers") @scope("Network")
  external fromChainId: (~chainId: int) => t = "from"
}

module JsonRpcProvider = {
  type t

  type rpcOptions = {
    staticNetwork?: Network.t,
    // Options for FallbackProvider
    /**
     *  The amount of time to wait before kicking off the next provider.
     *
     *  Any providers that have not responded can still respond and be
     *  counted, but this ensures new providers start.
     *  Default: 400ms
     */
    stallTimeout?: int,
    /**
     *  The priority. Lower priority providers are dispatched first.
     *  Default: 1
     */
    priority?: int,
    /**
     *  The amount of weight a provider is given against the quorum.
     *  Default: 1
     */
    weight?: int,
  }

  @module("ethers") @scope("ethers") @new
  external makeWithOptions: (~rpcUrl: string, ~network: Network.t, ~options: rpcOptions) => t =
    "JsonRpcProvider"

  let makeStatic = (~rpcUrl: string, ~network: Network.t, ~priority=?, ~stallTimeout=?): t => {
    makeWithOptions(~rpcUrl, ~network, ~options={staticNetwork: network, ?priority, ?stallTimeout})
  }

  let make = (~rpcUrl: string, ~chainId: int): t => {
    let network = Network.fromChainId(~chainId)
    makeStatic(~rpcUrl, ~network)
  }

  @send
  external getLogs: (t, ~filter: Filter.t) => promise<array<log>> = "getLogs"

  let makeGetTransactionFields = (~getTransactionByHash, ~lowercaseAddresses: bool) => async (
    log: log,
  ): promise<Internal.evmTransactionFields> => {
    let transaction: Internal.evmTransactionFields = await getTransactionByHash(log.transactionHash)
    // Mutating should be fine, since the transaction isn't used anywhere else outside the function
    let fields: {..} = transaction->Obj.magic

    // RPC may return null for transactionIndex on pending transactions
    fields["transactionIndex"] = log.transactionIndex

    // NOTE: this is wasteful if these fields are not selected in the users config.
    //       There might be a better way to do this in the `makeThrowingGetEventTransaction` function rather based on the schema.
    //       However this is not extremely expensive and good enough for now (only on rpc sync also).
    open Js.Nullable
    switch fields["from"] {
    | Value(from) =>
      fields["from"] = lowercaseAddresses
        ? from->Js.String2.toLowerCase->Address.unsafeFromString
        : from->Address.Evm.fromStringOrThrow
    | Undefined => ()
    | Null => ()
    }
    switch fields["to"] {
    | Value(to) =>
      fields["to"] = lowercaseAddresses
        ? to->Js.String2.toLowerCase->Address.unsafeFromString
        : to->Address.Evm.fromStringOrThrow
    | Undefined => ()
    | Null => ()
    }
    switch fields["contractAddress"] {
    | Value(contractAddress) =>
      fields["contractAddress"] = lowercaseAddresses
        ? contractAddress->Js.String2.toLowerCase->Address.unsafeFromString
        : contractAddress->Address.Evm.fromStringOrThrow
    | Undefined => ()
    | Null => ()
    }

    fields->Obj.magic
  }

  type block = {
    _difficulty: bigint,
    difficulty: int,
    extraData: Address.t,
    gasLimit: bigint,
    gasUsed: bigint,
    hash: string,
    miner: Address.t,
    nonce: int,
    number: int,
    parentHash: Address.t,
    timestamp: int,
    transactions: array<Address.t>,
  }

  @send
  external getBlock: (t, int) => promise<Js.nullable<block>> = "getBlock"
}
