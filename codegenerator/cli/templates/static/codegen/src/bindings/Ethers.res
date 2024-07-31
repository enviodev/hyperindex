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

type abi

let makeHumanReadableAbi = (abiArray: array<string>): abi => abiArray->Utils.magic

let makeAbi = (abi: Js.Json.t): abi => abi->Utils.magic

@genType.import(("./OpaqueTypes.ts", "EthersAddress"))
type ethAddress

@module("ethers") @scope("ethers")
external getAddressFromStringUnsafe: string => ethAddress = "getAddress"
/**
Same binding as getAddress from string 
but used when we receive and address that's not necessarily checksummed
*/
@module("ethers")
@scope("ethers")
external formatEthAddress: ethAddress => ethAddress = "getAddress"
let getAddressFromString = str => Misc.unsafeToOption(() => str->getAddressFromStringUnsafe)
external ethAddressToString: ethAddress => string = "%identity"
let ethAddressToStringLower = (address: ethAddress): string =>
  address->ethAddressToString->Js.String2.toLowerCase

let ethAddressSchema =
  S.string->S.setName("ethAddress")->(Utils.magic: S.t<string> => S.t<ethAddress>)

type txHash = string

module Constants = {
  @module("ethers") @scope("ethers") external zeroHash: string = "ZeroHash"
  @module("ethers") @scope("ethers") external zeroAddress: ethAddress = "ZeroAddress"
}

module Addresses = {
  @genType
  let mockAddresses = [
    "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266",
    "0x70997970C51812dc3A010C7d01b50e0d17dc79C8",
    "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC",
    "0x90F79bf6EB2c4f870365E785982E1f101E93b906",
    "0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65",
    "0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc",
    "0x976EA74026E726554dB657fA54763abd0C3a0aa9",
    "0x14dC79964da2C08b23698B3D3cc7Ca32193d9955",
    "0x23618e81E3f5cdF7f54C3d65f7FBc0aBf5B21E8f",
    "0xa0Ee7A142d267C1f36714E4a8F75612F20a79720",
    "0xBcd4042DE499D14e55001CcbB24a551F3b954096",
    "0x71bE63f3384f5fb98995898A86B02Fb2426c5788",
    "0xFABB0ac9d68B0B445fB7357272Ff202C5651694a",
    "0x1CBd3b2770909D4e10f157cABC84C7264073C9Ec",
    "0xdF3e18d64BC6A983f673Ab319CCaE4f1a57C7097",
    "0xcd3B766CCDd6AE721141F452C550Ca635964ce71",
    "0x2546BcD3c84621e976D8185a91A922aE77ECEc30",
    "0xbDA5747bFD65F08deb54cb465eB87D40e51B197E",
    "0xdD2FD4581271e230360230F9337D5c0430Bf44C0",
    "0x8626f6940E2eb28930eFb4CeF49B2d1F2C9C1199",
  ]->Belt.Array.map(getAddressFromStringUnsafe)
  @genType
  let defaultAddress =
    mockAddresses[0]
}

module BlockTag = {
  type t

  type semanticTag = [#latest | #earliest | #pending]
  type hexString = string
  type blockNumber = int

  type blockTagVariant = Latest | Earliest | Pending | HexString(string) | BlockNumber(int)

  let blockTagFromSemantic = (semanticTag: semanticTag): t => semanticTag->Utils.magic
  let blockTagFromBlockNumber = (blockNumber: blockNumber): t => blockNumber->Utils.magic
  let blockTagFromHexString = (hexString: hexString): t => hexString->Utils.magic

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
  type topic = string
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

  let filterFromRecord = (filterRecord: filterRecord): t => filterRecord->Utils.magic
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
    combinedFilter->Utils.magic
}

type log = {
  blockNumber: int,
  blockHash: string,
  removed: option<bool>,
  //Note: this is the index of the log in the transaction and should be used whenever we use "logIndex"
  address: ethAddress,
  data: string,
  topics: array<EventFilter.topic>,
  transactionHash: txHash,
  transactionIndex: int,
  //Note: this logIndex is the index of the log in the block, not the transaction
  @as("index") logIndex: int,
}

type minimumParseableLogData = {topics: array<EventFilter.topic>, data: string}

//Can safely convert from log to minimumParseableLogData since it contains
//both data points required
let logToMinimumParseableLogData: log => minimumParseableLogData = Utils.magic

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

  type fallbackProviderOptions = {
    // How many providers must agree on a value before reporting
    // back the response
    // Note: Default the half of the providers weight, so we need to set it to accept result from the first rpc
    quorum?: int,
  }

  @module("ethers") @scope("ethers") @new
  external makeWithOptions: (~rpcUrl: string, ~network: Network.t, ~options: rpcOptions) => t =
    "JsonRpcProvider"

  @module("ethers") @scope("ethers") @new
  external makeFallbackProvider: (
    ~providers: array<t>,
    ~network: Network.t,
    ~options: fallbackProviderOptions,
  ) => t = "FallbackProvider"

  let makeStatic = (~rpcUrl: string, ~network: Network.t, ~priority=?, ~stallTimeout=?): t => {
    makeWithOptions(~rpcUrl, ~network, ~options={staticNetwork: network, ?priority, ?stallTimeout})
  }

  let make = (~rpcUrls: array<string>, ~chainId: int, ~fallbackStallTimeout): t => {
    let network = Network.fromChainId(~chainId)
    switch rpcUrls {
    | [rpcUrl] => makeStatic(~rpcUrl, ~network)
    | rpcUrls =>
      makeFallbackProvider(
        ~providers=rpcUrls->Js.Array2.mapi((rpcUrl, index) =>
          makeStatic(~rpcUrl, ~network, ~priority=index, ~stallTimeout=fallbackStallTimeout)
        ),
        ~network,
        ~options={
          quorum: 1,
        },
      )
    }
  }

  @send
  external getLogs: (t, ~filter: Filter.t) => promise<array<log>> = "getLogs"

  type listenerEvent = [#block]
  @send external onEventListener: (t, listenerEvent, int => unit) => unit = "on"

  @send external offAllEventListeners: (t, listenerEvent) => unit = "off"

  let onBlock = (t, callback: int => unit) => t->onEventListener(#block, callback)

  let removeOnBlockEventListener = t => t->offAllEventListeners(#block)

  @send
  external getBlockNumber: t => promise<int> = "getBlockNumber"

  type block = {
    _difficulty: bigint,
    difficulty: int,
    extraData: ethAddress,
    gasLimit: bigint,
    gasUsed: bigint,
    hash: string,
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

module EventFragment = {
  //Note there are more properties and methods to bind to
  type t = {
    name: string,
    anonymous: bool,
    topicHash: EventFilter.topic,
  }
}

module Interface = {
  type t
  @module("ethers") @scope("ethers") @new external make: (~abi: abi) => t = "Interface"
  @send
  external parseLogUnsafe: (t, ~log: minimumParseableLogData) => Js.Nullable.t<logDescription<'a>> =
    "parseLog"

  type parseLogError = EventNotFound | ParseError(exn)

  let parseLog = (interface: t, ~log: log): Belt.Result.t<logDescription<'a>, parseLogError> => {
    try {
      let parsed = interface->parseLogUnsafe(~log=log->logToMinimumParseableLogData)
      switch parsed->Js.Nullable.toOption {
      | Some(val) => Ok(val)
      | None => Error(EventNotFound)
      }
    } catch {
    | e => Error(ParseError(e))
    }
  }

  @send external parseLogJson: (t, ~log: log) => logDescription<Js.Json.t> = "parseLog"

  @send external forEachEvent: (t, (EventFragment.t, int) => unit) => unit = "forEachEvent"
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
