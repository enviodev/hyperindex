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
