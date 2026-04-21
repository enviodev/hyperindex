open Vitest

// Tests for the per-event `startBlock` extracted from `where.block` on the
// `onEvent` filter. The parser lives in `LogSelection.parseEventFiltersOrThrow`
// and composes the ecosystem-specific `onEventBlockFilterSchema` (strips
// `block.number` on EVM, `block.height` on Fuel) with the shared
// `eventBlockRangeSchema` (strict, `_gte`-only). These tests drive the parser
// directly so we don't have to bring up a full indexer.
//
// The canonical ERC-20 Transfer sighash is used as a valid topic0 — the
// parser requires a sighash but the content doesn't matter for these cases.

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

let parseFuel = (~eventFilters: option<JSON.t>, ~probeChainId=1) =>
  LogSelection.parseEventFiltersOrThrow(
    ~eventFilters,
    ~sighash=transferSighash,
    ~params=["from", "to"],
    ~contractName="ERC20",
    ~probeChainId,
    ~onEventBlockFilterSchema=Fuel.ecosystem.onEventBlockFilterSchema,
  )

describe("eventBlockRangeSchema (strict, _gte-only)", () => {
  it("parses a lone _gte", t => {
    let parsed = %raw(`{_gte: 10}`)->S.parseOrThrow(LogSelection.eventBlockRangeSchema)
    t.expect(parsed).toEqual(({_gte: Some(10)}: LogSelection.eventBlockRange))
  })

  it("rejects _lte (use onBlock for ranges)", t => {
    t.expect(() =>
      %raw(`{_gte: 10, _lte: 100}`)->S.parseOrThrow(LogSelection.eventBlockRangeSchema)
    ).toThrow()
  })

  it("rejects _every (use onBlock for stride)", t => {
    t.expect(() =>
      %raw(`{_gte: 10, _every: 5}`)->S.parseOrThrow(LogSelection.eventBlockRangeSchema)
    ).toThrow()
  })

  it("rejects typos (_gt)", t => {
    t.expect(() => %raw(`{_gt: 10}`)->S.parseOrThrow(LogSelection.eventBlockRangeSchema)).toThrow()
  })

  it("accepts an empty object (no startBlock)", t => {
    let parsed = %raw(`{}`)->S.parseOrThrow(LogSelection.eventBlockRangeSchema)
    t.expect(parsed).toEqual(({_gte: None}: LogSelection.eventBlockRange))
  })
})

describe("parseEventFiltersOrThrow — static `where` with block filter (EVM)", () => {
  it("extracts startBlock from a bare block filter", t => {
    let {startBlock, filterByAddresses} = parseEvm(
      ~eventFilters=Some(%raw(`{block: {number: {_gte: 1000}}}`)),
    )
    t.expect((startBlock, filterByAddresses)).toEqual((Some(1000), false))
  })

  it("extracts startBlock alongside params (combined filter)", t => {
    let {startBlock} = parseEvm(
      ~eventFilters=Some(
        %raw(`{block: {number: {_gte: 2000}}, params: {from: "0x0000000000000000000000000000000000000000"}}`),
      ),
    )
    t.expect(startBlock).toEqual(Some(2000))
  })

  it("returns None when `where` has no block filter", t => {
    let {startBlock} = parseEvm(
      ~eventFilters=Some(%raw(`{params: {from: "0x0000000000000000000000000000000000000000"}}`)),
    )
    t.expect(startBlock).toEqual(None)
  })

  it("returns None when `where` is `{block: {}}` (no number field)", t => {
    let {startBlock} = parseEvm(~eventFilters=Some(%raw(`{block: {}}`)))
    t.expect(startBlock).toEqual(None)
  })

  it("returns None when `block.number: {}` (no _gte)", t => {
    let {startBlock} = parseEvm(~eventFilters=Some(%raw(`{block: {number: {}}}`)))
    t.expect(startBlock).toEqual(None)
  })

  it("returns None when `eventFilters` is None (no where option)", t => {
    let {startBlock} = parseEvm(~eventFilters=None)
    t.expect(startBlock).toEqual(None)
  })

  it("rejects `_lte` on event filters with a helpful message", t => {
    t.expect(() =>
      parseEvm(
        ~eventFilters=Some(%raw(`{block: {number: {_gte: 10, _lte: 200}}}`)),
      )->ignore
    ).toThrowError("Only `_gte` is supported on event filters")
  })

  it("rejects `_every` on event filters", t => {
    t.expect(() =>
      parseEvm(
        ~eventFilters=Some(%raw(`{block: {number: {_gte: 10, _every: 5}}}`)),
      )->ignore
    ).toThrowError("Only `_gte` is supported on event filters")
  })

  it("rejects unknown top-level keys (typo catches)", t => {
    t.expect(() =>
      parseEvm(~eventFilters=Some(%raw(`{blocks: {number: {_gte: 10}}}`)))->ignore
    ).toThrowError(`Unknown field "blocks"`)
  })
})

describe("parseEventFiltersOrThrow — dynamic `where` callback (EVM)", () => {
  it("extracts startBlock from the probe result for the configured chain", t => {
    // The callback is evaluated once at build time against `probeChainId`
    // so the probe exercises the branch this event config is built for.
    let whereFn = %raw(`({chain}) => ({
      block: {number: {_gte: chain.id === 137 ? 5000 : 1000}},
      params: {from: "0x0000000000000000000000000000000000000000"},
    })`)
    let {startBlock: startBlockChain137} = parseEvm(
      ~eventFilters=Some(whereFn),
      ~probeChainId=137,
    )
    let {startBlock: startBlockChain1} = parseEvm(~eventFilters=Some(whereFn), ~probeChainId=1)
    t.expect((startBlockChain137, startBlockChain1)).toEqual((Some(5000), Some(1000)))
  })

  it("returns None when the callback returns `false` for this chain", t => {
    let whereFn = %raw(`({chain}) => chain.id === 137 ? {block: {number: {_gte: 5000}}} : false`)
    let {startBlock} = parseEvm(~eventFilters=Some(whereFn), ~probeChainId=1)
    t.expect(startBlock).toEqual(None)
  })

  it("returns None when the callback returns `true`", t => {
    let whereFn = %raw(`({chain: _chain}) => true`)
    let {startBlock} = parseEvm(~eventFilters=Some(whereFn))
    t.expect(startBlock).toEqual(None)
  })
})

describe("parseEventFiltersOrThrow — Fuel block.height", () => {
  it("extracts startBlock from `block.height._gte`", t => {
    let {startBlock} = parseFuel(~eventFilters=Some(%raw(`{block: {height: {_gte: 42}}}`)))
    t.expect(startBlock).toEqual(Some(42))
  })

  it("Fuel rejects `block.number` (must use height)", t => {
    // The ecosystem schema key is `height`, so `number` is ignored at the
    // outer level (surfaces as None) and the event runs with no startBlock
    // override — the user opts into Fuel's shape via the TS type.
    let {startBlock} = parseFuel(~eventFilters=Some(%raw(`{block: {number: {_gte: 42}}}`)))
    t.expect(startBlock).toEqual(None)
  })
})

// Compile-time check that the generated `onEventWhereCondition` type on a
// real codegen'd event module carries the `block` sibling of `params`.
// Running this test as a value also verifies that the optional fields'
// shape is preserved end-to-end — the ReScript record unwrapped to JSON
// matches exactly what `LogSelection.parseEventFiltersOrThrow` expects.
describe("Generated onEventWhereCondition — block field exists on EVM events", () => {
  it("compiles a `Filter` with combined params + block.number._gte", t => {
    let fromFilter: Indexer.EventFiltersTest.Transfer.whereParams = {
      from: Indexer.SingleOrMultiple.single(
        "0x0000000000000000000000000000000000000000"->Address.unsafeFromString,
      ),
    }
    let condition: Indexer.EventFiltersTest.Transfer.onEventWhereCondition = {
      params: Indexer.SingleOrMultiple.single(fromFilter),
      block: {number: {_gte: 1000}},
    }
    // Round-trip the generated record through the runtime parser to prove
    // the codegen'd shape decodes into the expected startBlock — the only
    // guarantee that really matters downstream.
    let {startBlock} = parseEvm(
      ~eventFilters=Some(
        condition->(
          Utils.magic: Indexer.EventFiltersTest.Transfer.onEventWhereCondition => JSON.t
        ),
      ),
    )
    t.expect(startBlock).toEqual(Some(1000))
  })

  it("compiles a `Filter` with only block (no params)", t => {
    let condition: Indexer.EventFiltersTest.Transfer.onEventWhereCondition = {
      block: {number: {_gte: 2500}},
    }
    // Round-trip through the runtime parser to prove the record encodes to
    // the shape the parser understands — catches any drift between
    // codegen'd types and runtime expectations.
    let {startBlock} = parseEvm(~eventFilters=Some(condition->(Utils.magic: Indexer.EventFiltersTest.Transfer.onEventWhereCondition => JSON.t)))
    t.expect(startBlock).toEqual(Some(2500))
  })
})

// Integration: the full `buildEvmEventConfig` path sees the `block` filter
// and writes it to `eventConfig.startBlock`, overriding the contract-level
// value. This is the seam that `FetchState` reads when partitioning —
// unit-testing it here avoids a full-indexer bring-up while still proving
// the override semantics.
describe("EventConfigBuilder — where.block.number._gte overrides contract startBlock", () => {
  let transferParams: array<EventConfigBuilder.eventParam> = [
    {name: "from", abiType: "address", indexed: true},
    {name: "to", abiType: "address", indexed: true},
    {name: "value", abiType: "uint256", indexed: false},
  ]

  let build = (~eventFilters: option<JSON.t>, ~startBlock: option<int>=?) =>
    EventConfigBuilder.buildEvmEventConfig(
      ~contractName="ERC20",
      ~eventName="Transfer",
      ~sighash=transferSighash,
      ~params=transferParams,
      ~isWildcard=true,
      ~handler=None,
      ~contractRegister=None,
      ~eventFilters,
      ~probeChainId=1,
      ~onEventBlockFilterSchema=Evm.ecosystem.onEventBlockFilterSchema,
      ~startBlock?,
    )

  it("promotes `where.block.number._gte` to eventConfig.startBlock", t => {
    let ec = build(~eventFilters=Some(%raw(`{block: {number: {_gte: 1000}}}`)))
    t.expect(ec.startBlock).toEqual(Some(1000))
  })

  it("overrides the contract-level startBlock when where.block is present", t => {
    let ec = build(~eventFilters=Some(%raw(`{block: {number: {_gte: 1500}}}`)), ~startBlock=100)
    t.expect(ec.startBlock).toEqual(Some(1500))
  })

  it("falls back to the contract-level startBlock when where.block is absent", t => {
    let ec = build(
      ~eventFilters=Some(%raw(`{params: {from: "0x0000000000000000000000000000000000000000"}}`)),
      ~startBlock=100,
    )
    t.expect(ec.startBlock).toEqual(Some(100))
  })

  it("leaves startBlock as None when neither is provided", t => {
    let ec = build(~eventFilters=None)
    t.expect(ec.startBlock).toEqual(None)
  })

  it("dynamic where callback — per-chain startBlock wins over contract value", t => {
    let whereFn = %raw(`({chain}) => ({block: {number: {_gte: chain.id === 137 ? 5000 : 250}}})`)
    let chain137 = EventConfigBuilder.buildEvmEventConfig(
      ~contractName="ERC20",
      ~eventName="Transfer",
      ~sighash=transferSighash,
      ~params=transferParams,
      ~isWildcard=true,
      ~handler=None,
      ~contractRegister=None,
      ~eventFilters=Some(whereFn),
      ~probeChainId=137,
      ~onEventBlockFilterSchema=Evm.ecosystem.onEventBlockFilterSchema,
      ~startBlock=1,
    )
    let chain1 = EventConfigBuilder.buildEvmEventConfig(
      ~contractName="ERC20",
      ~eventName="Transfer",
      ~sighash=transferSighash,
      ~params=transferParams,
      ~isWildcard=true,
      ~handler=None,
      ~contractRegister=None,
      ~eventFilters=Some(whereFn),
      ~probeChainId=1,
      ~onEventBlockFilterSchema=Evm.ecosystem.onEventBlockFilterSchema,
      ~startBlock=1,
    )
    t.expect((chain137.startBlock, chain1.startBlock)).toEqual((Some(5000), Some(250)))
  })
})

// End-to-end through FetchState: the per-event `startBlock` (derived from
// `where.block.number._gte`) propagates to the partition's per-address
// `effectiveStartBlock`, which is what the fetcher reads to gate
// `getItemsOrThrow` calls for non-wildcard events. Mirrors the existing
// dynamic-contract startBlock tests but exercises the static-address path
// a `where`-filtered `onEvent` call takes.
describe("FetchState — eventConfig.startBlock from where.block gates address start", () => {
  let mockAddress =
    Envio.TestHelpers.Addresses.mockAddresses[0]->Option.getOrThrow

  let buildEvmTransfer = (~startBlock: option<int>) =>
    EventConfigBuilder.buildEvmEventConfig(
      ~contractName="ERC20",
      ~eventName="Transfer",
      ~sighash=transferSighash,
      ~params=[
        {name: "from", abiType: "address", indexed: true},
        {name: "to", abiType: "address", indexed: true},
        {name: "value", abiType: "uint256", indexed: false},
      ],
      ~isWildcard=false,
      ~handler=None,
      ~contractRegister=None,
      ~eventFilters=Some(%raw(`{block: {number: {_gte: 5000}}}`)),
      ~probeChainId=1,
      ~onEventBlockFilterSchema=Evm.ecosystem.onEventBlockFilterSchema,
      ~startBlock?,
    )

  it("partition addressable entry's effectiveStartBlock reflects where.block._gte", t => {
    let ec = buildEvmTransfer(~startBlock=None)
    let fetchState = FetchState.make(
      ~eventConfigs=[(ec :> Internal.eventConfig)],
      ~addresses=[
        {
          Internal.address: mockAddress,
          contractName: "ERC20",
          registrationBlock: -1,
        },
      ],
      ~startBlock=0,
      ~endBlock=None,
      ~maxAddrInPartition=3,
      ~targetBufferSize=5000,
      ~chainId=1,
      ~knownHeight=10000,
    )
    let indexingAddress =
      fetchState.indexingAddresses
      ->Dict.get(mockAddress->Address.toString)
      ->Option.getOrThrow
    // `-1` registrationBlock + `contractStartBlock=Some(5000)` collapses
    // to `effectiveStartBlock=5000`. The fetcher uses this as the floor
    // for this address's event queries.
    t.expect(indexingAddress.effectiveStartBlock).toEqual(5000)
  })

  it("where.block._gte overrides a smaller contract-level startBlock on the partition", t => {
    // Contract-level startBlock (from `config.yaml`) is 100; the where
    // filter bumps it to 5000 — the partition sees the override, not the
    // config value.
    let ec = buildEvmTransfer(~startBlock=Some(100))
    let fetchState = FetchState.make(
      ~eventConfigs=[(ec :> Internal.eventConfig)],
      ~addresses=[
        {
          Internal.address: mockAddress,
          contractName: "ERC20",
          registrationBlock: -1,
        },
      ],
      ~startBlock=0,
      ~endBlock=None,
      ~maxAddrInPartition=3,
      ~targetBufferSize=5000,
      ~chainId=1,
      ~knownHeight=10000,
    )
    let indexingAddress =
      fetchState.indexingAddresses
      ->Dict.get(mockAddress->Address.toString)
      ->Option.getOrThrow
    t.expect(indexingAddress.effectiveStartBlock).toEqual(5000)
  })
})
