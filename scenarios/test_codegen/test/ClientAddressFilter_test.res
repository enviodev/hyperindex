open Vitest

// Direct tests for the client-side address filter: the `where`-callback
// detection (`addressFilterParamGroups`) in `LogSelection.parseEventFiltersOrThrow`
// and the precompiled `clientAddressFilter` built in `EventConfigBuilder`.

let transferSighash = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"

let parseEvm = (~eventFilters: option<JSON.t>, ~probeChainId=1) =>
  LogSelection.parseEventFiltersOrThrow(
    ~eventFilters,
    ~sighash=transferSighash,
    ~params=["from", "to"],
    ~contractName="ERC20",
    ~probeChainId,
    ~onEventBlockFilterSchema=Evm.ecosystem.onEventBlockFilterSchema,
  )

describe("parseEventFiltersOrThrow — address-param detection", () => {
  it("collects the address-filtered param (single group)", t => {
    let {filterByAddresses, addressFilterParamGroups} = parseEvm(
      ~eventFilters=Some(%raw(`({chain}) => ({params: {to: chain.ERC20.addresses}})`)),
    )
    t.expect((filterByAddresses, addressFilterParamGroups)).toEqual((true, [["to"]]))
  })

  it("collects OR of groups and ignores constant params", t => {
    // Mirrors the WildcardWithAddress handler: each group pairs the registry
    // addresses with a constant; only the registry-sourced param is collected.
    let {addressFilterParamGroups} = parseEvm(
      ~eventFilters=Some(
        %raw(`({chain}) => {
          const a = chain.ERC20.addresses;
          return {params: [
            {from: "0x0000000000000000000000000000000000000000", to: a},
            {from: a, to: "0x0000000000000000000000000000000000000000"},
          ]};
        }`),
      ),
    )
    t.expect(addressFilterParamGroups).toEqual([["to"], ["from"]])
  })

  it("has no address-param groups for a static filter", t => {
    let {filterByAddresses, addressFilterParamGroups} = parseEvm(
      ~eventFilters=Some(%raw(`{params: {from: "0x0000000000000000000000000000000000000000"}}`)),
    )
    t.expect((filterByAddresses, addressFilterParamGroups)).toEqual((false, []))
  })

  it("throws when the addresses are transformed instead of passed directly", t => {
    t.expect(() =>
      parseEvm(
        ~eventFilters=Some(%raw(`({chain}) => ({params: {to: [...chain.ERC20.addresses]}})`)),
      )->ignore
    ).toThrowError("must be passed directly as an indexed-param filter value")
  })

  it("throws when addresses are read but not used as a param filter", t => {
    t.expect(() =>
      parseEvm(
        ~eventFilters=Some(%raw(`({chain}) => { const _a = chain.ERC20.addresses; return true }`)),
      )->ignore
    ).toThrowError("doesn't use it as an indexed-param filter value")
  })
})

describe("clientAddressFilter — precompiled predicate", () => {
  let transferParams: array<EventConfigBuilder.paramMeta> = [
    {name: "from", abiType: "address", indexed: true},
    {name: "to", abiType: "address", indexed: true},
    {name: "value", abiType: "uint256", indexed: false},
  ]

  let buildFilter = (~eventFilters: JSON.t) =>
    EventConfigBuilder.buildEvmEventConfig(
      ~contractName="ERC20",
      ~eventName="Transfer",
      ~sighash=transferSighash,
      ~params=transferParams,
      ~isWildcard=true,
      ~handler=None,
      ~contractRegister=None,
      ~eventFilters=Some(eventFilters),
      ~probeChainId=1,
      ~onEventBlockFilterSchema=Evm.ecosystem.onEventBlockFilterSchema,
    ).clientAddressFilter

  let addr = "0x1111111111111111111111111111111111111111"->Address.unsafeFromString
  let zero = "0x0000000000000000000000000000000000000000"->Address.unsafeFromString
  let indexingAddresses = Dict.fromArray([
    (
      addr->Address.toString,
      (
        {
          Internal.address: addr,
          contractName: "ERC20",
          registrationBlock: 5,
          effectiveStartBlock: 5,
        }: Internal.indexingContract
      ),
    ),
  ])
  let makeEvent = (~from, ~to, ~blockNumber) =>
    {"params": {"from": from, "to": to}, "block": {"number": blockNumber}}->(
      Utils.magic: {
        "params": {"from": Address.t, "to": Address.t},
        "block": {"number": int},
      } => Internal.event
    )

  it("keeps events whose address param is registered at/before the block, drops the rest", t => {
    // OR over `to` (group 1) and `from` (group 2), each registry-filtered.
    let filter =
      buildFilter(
        ~eventFilters=%raw(`({chain}) => {
          const a = chain.ERC20.addresses;
          return {params: [
            {from: "0x0000000000000000000000000000000000000000", to: a},
            {from: a, to: "0x0000000000000000000000000000000000000000"},
          ]};
        }`),
      )->Option.getOrThrow
    t.expect((
      filter(makeEvent(~from=zero, ~to=addr, ~blockNumber=10), indexingAddresses),
      filter(makeEvent(~from=zero, ~to=addr, ~blockNumber=5), indexingAddresses),
      filter(makeEvent(~from=zero, ~to=addr, ~blockNumber=4), indexingAddresses),
      filter(makeEvent(~from=addr, ~to=zero, ~blockNumber=10), indexingAddresses),
      filter(makeEvent(~from=zero, ~to=zero, ~blockNumber=10), indexingAddresses),
    )).toEqual((true, true, false, true, false))
  })

  it("is absent for events without an address-param filter", t => {
    t.expect((
      buildFilter(
        ~eventFilters=%raw(`{params: {from: "0x0000000000000000000000000000000000000000"}}`),
      )->Option.isNone,
      buildFilter(~eventFilters=%raw(`{block: {number: {_gte: 10}}}`))->Option.isNone,
    )).toEqual((true, true))
  })
})

describe("FetchState.handleQueryResult applies clientAddressFilter", () => {
  let transferParams: array<EventConfigBuilder.paramMeta> = [
    {name: "from", abiType: "address", indexed: true},
    {name: "to", abiType: "address", indexed: true},
    {name: "value", abiType: "uint256", indexed: false},
  ]

  // Wildcard Transfer filtering `to` by the registered ERC20 addresses; the
  // single config address is effective from block 5 (contract startBlock).
  let registeredAddr = "0x2222222222222222222222222222222222222222"->Address.unsafeFromString
  let eventConfig = EventConfigBuilder.buildEvmEventConfig(
    ~contractName="ERC20",
    ~eventName="Transfer",
    ~sighash=transferSighash,
    ~params=transferParams,
    ~isWildcard=true,
    ~handler=None,
    ~contractRegister=None,
    ~eventFilters=Some(%raw(`({chain}) => ({params: {to: chain.ERC20.addresses}})`)),
    ~probeChainId=1,
    ~onEventBlockFilterSchema=Evm.ecosystem.onEventBlockFilterSchema,
    ~startBlock=5,
  )

  let makeItem = (~to, ~blockNumber): Internal.item =>
    Internal.Event({
      timestamp: blockNumber * 15,
      chain: ChainMap.Chain.makeUnsafe(~chainId=1),
      blockNumber,
      blockHash: `0x${blockNumber->Int.toString}`,
      eventConfig: (eventConfig :> Internal.eventConfig),
      logIndex: 0,
      event: {"params": {"to": to}, "block": {"number": blockNumber}}->(
        Utils.magic: {"params": {"to": Address.t}, "block": {"number": int}} => Internal.event
      ),
    })

  it("drops over-fetched events before the param-address's registration block", t => {
    let fetchState = FetchState.make(
      ~eventConfigs=[(eventConfig :> Internal.eventConfig)],
      ~addresses=[{Internal.address: registeredAddr, contractName: "ERC20", registrationBlock: -1}],
      ~startBlock=0,
      ~endBlock=None,
      ~maxAddrInPartition=10,
      ~targetBufferSize=5000,
      ~chainId=1,
      ~knownHeight=1000,
    )
    let query = switch fetchState->FetchState.getNextQuery(~concurrencyLimit=10) {
    | Ready([q]) => q
    | _ => JsError.throwWithMessage("expected a single ready query")
    }
    fetchState->FetchState.startFetchingQueries(~queries=[query])
    let updated =
      fetchState->FetchState.handleQueryResult(
        ~query,
        ~latestFetchedBlock={blockNumber: 20, blockTimestamp: 300},
        // to=registeredAddr (effectiveStartBlock 5): block 10 kept, block 3 dropped.
        ~newItems=[makeItem(~to=registeredAddr, ~blockNumber=10), makeItem(~to=registeredAddr, ~blockNumber=3)],
      )
    t.expect(updated.buffer->Array.map(item => item->Internal.getItemBlockNumber)).toEqual([10])
  })
})
