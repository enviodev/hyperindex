type t
@module("ethers") external ethersCheck: t = "ethers"

module Misc = {
  let unsafeToOption: (unit => 'a) => option<'a> = unsafeFunc => {
    try {
      unsafeFunc()->Some
    } catch {
    | Js.Exn.Error(_obj) => None
    }
  }
}

module BigInt = {
  @genType.import(("./OpaqueTypes","GenericBigInt"))
  type t

  // constructors and methods
  @val external fromInt: int => t = "BigInt"
  @val external fromStringUnsafe: string => t = "BigInt"
  let fromString = str => Misc.unsafeToOption(() => str->fromStringUnsafe)
  @send external toString: t => string = "toString"

  //silence unused var warnings for raw bindings
  @@warning("-27")
  // operation
  let add = (a: t, b: t): t => %raw("a + b")
  let sub = (a: t, b: t): t => %raw("a - b")
  let mul = (a: t, b: t): t => %raw("a * b")
  let div = (a: t, b: t): t => %raw("b > 0n ? a / b : 0n")
  let pow = (a: t, b: t): t => %raw("a ** b")
  let mod = (a: t, b: t): t => %raw("b > 0n ? a % b : 0n")

  // comparison
  let eq = (a: t, b: t): bool => %raw("a === b")
  let neq = (a: t, b: t): bool => %raw("a !== b")
  let gt = (a: t, b: t): bool => %raw("a > b")
  let gte = (a: t, b: t): bool => %raw("a >= b")
  let lt = (a: t, b: t): bool => %raw("a < b")
  let lte = (a: t, b: t): bool => %raw("a <= b")
  module Bitwise = {
    let shift_left = (a: t, b: t): t => %raw("a << b")
    let shift_right = (a: t, b: t): t => %raw("a >> b")
    let logor = (a: t, b: t): t => %raw("a | b")
    let logand = (a: t, b: t): t => %raw("a & b")
  }

}

type abi

let makeHumanReadableAbi = (abiArray: array<string>): abi => abiArray->Obj.magic

let makeAbi = (abi: Js.Json.t): abi => abi->Obj.magic

@genType.import(("./OpaqueTypes","EthersAddress"))
type ethAddress

@module("ethers") @scope("ethers")
external getAddressFromStringUnsafe: string => ethAddress = "getAddress"
let getAddressFromString = str => Misc.unsafeToOption(() => str->getAddressFromStringUnsafe)
let ethAddressToString = (address: ethAddress): string => address->Obj.magic
let ethAddressToStringLower = (address: ethAddress): string =>
  address->ethAddressToString->Js.String2.toLowerCase

type txHash = string

module BlockTag = {
  type t

  type semanticTag = [#latest | #earliest | #pending]
  type hexString = string
  type blockNumber = int

  type blockTagVariant = Latest | Earliest | Pending | HexString(string) | BlockNumber(int)

  let blockTagFromSemantic = (semanticTag: semanticTag): t => semanticTag->Obj.magic
  let blockTagFromBlockNumber = (blockNumber: blockNumber): t => blockNumber->Obj.magic
  let blockTagFromHexString = (hexString: hexString): t => hexString->Obj.magic

  let blockTagFromVariant = variant =>
    switch variant {
    | Latest => #latest->blockTagFromSemantic
    | Earliest => #earliest->blockTagFromSemantic
    | Pending => #pending->blockTagFromSemantic
    | HexString(str) => str->blockTagFromHexString
    | BlockNumber(num) => num->blockTagFromBlockNumber
    }
}

module EventFilter = {
  type topic
  type t = {
    address: ethAddress,
    topics: array<topic>,
  }
}
module Filter = {
  type t

  //This can be used as a filter but should not assume all filters  are the same type
  //address could be an array of addresses like in combined filter
  type filterRecord = {
    address: ethAddress,
    topics: array<EventFilter.topic>,
    fromBlock: BlockTag.t,
    toBlock: BlockTag.t,
  }

  let filterFromRecord = (filterRecord: filterRecord): t => filterRecord->Obj.magic
}

module CombinedFilter = {
  type combinedFilterRecord = {
    address: array<ethAddress>,
    //The second element of the tuple is the
    topics: array<array<EventFilter.topic>>,
    fromBlock: BlockTag.t,
    toBlock: BlockTag.t,
  }
  let combineEventFilters = (eventFilters: array<EventFilter.t>, ~fromBlock, ~toBlock) => {
    let addresses = eventFilters->Belt.Array.reduce([], (currentAddresses, filter) => {
      let isNewAddress = !(currentAddresses->Js.Array2.includes(filter.address))
      isNewAddress ? Belt.Array.concat(currentAddresses, [filter.address]) : currentAddresses
    })
    //Only take the first topic from each filter which is the signature without indexed params
    // This combined filter will not work to filter by indexed param

    let topicsArr =
      eventFilters
      ->Belt.Array.keepMap(filter => filter.topics->Belt.Array.get(0))
      ->Belt.Array.reduce([], (currentTopics, topic) => {
        let isNewFilter = !(currentTopics->Js.Array2.includes(topic))
        isNewFilter ? Belt.Array.concat(currentTopics, [topic]) : currentTopics
      })

    {
      address: addresses,
      topics: [topicsArr],
      fromBlock,
      toBlock,
    }
  }

  let combinedFilterToFilter = (combinedFilter: combinedFilterRecord): Filter.t =>
    combinedFilter->Obj.magic
}

type log = {
  blockNumber: int,
  blockHash: string,
  removed: bool,
  //Note: this is the index of the log in the transaction and should be used whenever we use "logIndex"
  address: ethAddress,
  data: string,
  topics: array<string>,
  transactionHash: txHash,
  transactionIndex: int,
  //Note: this logIndex is the index of the log in the block, not the transaction
  @as("index") logIndex: int,
}

type logDescription<'a> = {
  args: 'a,
  name: string,
  signature: string,
  topic: string,
}

module PreparedTopicFilter = {
  /** The type returend by contract.filters.\<Event>() */
  type t

  @get @scope("fragment") external getTopicHash: t => EventFilter.topic = "topicHash"
}

module JsonRpcProvider = {
  type t
  @module("ethers") @scope("ethers") @new
  external make: (~rpcUrl: string, ~chainId: int) => t = "JsonRpcProvider"

  @send
  external getLogs: (t, ~filter: Filter.t) => promise<array<log>> = "getLogs"

  type blockStr = [#block]
  @send external onWithBlockNoReturn: (t, blockStr, int => unit) => unit = "on"

  let onBlock = (t, callback: int => unit) => t->onWithBlockNoReturn(#block, callback)

  @send
  external getBlockNumber: t => promise<int> = "getBlockNumber"

  type block = {
    _difficulty: BigInt.t,
    difficulty: int,
    extraData: ethAddress,
    gasLimit: BigInt.t,
    gasUsed: BigInt.t,
    hash: ethAddress,
    miner: ethAddress,
    nonce: int,
    number: int,
    parentHash: ethAddress,
    timestamp: int,
    transactions: array<ethAddress>,
  }

  @send
  external getBlock: (t, int) => promise<Js.nullable<block>> = "getBlock"
}

module Interface = {
  type t
  @module("ethers") @scope("ethers") @new external make: (~abi: abi) => t = "Interface"
  @send external parseLog: (t, ~log: log) => logDescription<'a> = "parseLog"
  @send external parseLogJson: (t, ~log: log) => logDescription<Js.Json.t> = "parseLog"
}

module Contract = {
  type t
  @module("ethers") @scope("ethers") @new
  external make: (~address: ethAddress, ~abi: abi, ~provider: JsonRpcProvider.t) => t = "Contract"

  @get external getEthAddress: t => ethAddress = "target"
  @get external getInterface: t => Interface.t = "interface"

  @ocaml.warning("-27")
  let getPreparedTopicFilter = (contract: t, ~eventName: string): option<PreparedTopicFilter.t> =>
    Misc.unsafeToOption(() => %raw("contract.filters[eventName]()"))

  let getEventFilter = (contract: t, ~eventName: string): EventFilter.t => {
    let address = contract->getEthAddress
    let topics =
      contract
      ->getPreparedTopicFilter(~eventName)
      ->Belt.Option.mapWithDefault([], preparedTopicFilter => [
        preparedTopicFilter->PreparedTopicFilter.getTopicHash,
      ])

    {address, topics}
  }
}
