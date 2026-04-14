open Vitest

// Tests for the two-stage parse that backs `indexer.onBlock` / `indexer.onSlot`:
//   1. Each ecosystem's `onBlockFilterSchema` unwraps its outer wrapper
//      (`block.number` / `block.height` / `slot`) and surfaces the inner
//      range chunk as `option<unknown>`.
//   2. The shared `blockRangeSchema` on `Main` validates the inner
//      `{_gte?, _lte?, _every?}` — strict (typos throw), `_every` defaults
//      to 1, optional bounds stay `None`.
//
// These tests drive the schemas directly so we don't have to bring up a
// runtime indexer; the consumer in `Main.onBlockFn` composes them in the
// same order as `extractRange`.

describe("blockRangeSchema (shared inner range validation)", () => {
  it("parses all three fields", t => {
    let parsed =
      %raw(`{_gte: 100, _lte: 200, _every: 5}`)->S.parseOrThrow(Main.blockRangeSchema)
    t.expect(parsed).toEqual(({_gte: Some(100), _lte: Some(200), _every: 5}: Main.blockRange))
  })

  it("defaults _every to 1 when omitted", t => {
    let parsed = %raw(`{_gte: 10}`)->S.parseOrThrow(Main.blockRangeSchema)
    t.expect(parsed).toEqual(({_gte: Some(10), _lte: None, _every: 1}: Main.blockRange))
  })

  it("accepts an empty object (all bounds optional, _every defaulted)", t => {
    let parsed = %raw(`{}`)->S.parseOrThrow(Main.blockRangeSchema)
    t.expect(parsed).toEqual(Main.defaultBlockRange)
  })

  it("S.strict rejects unknown fields (typo catches)", t => {
    // `_gt` (typo for `_gte`) must not be silently accepted.
    t.expect(() => %raw(`{_gt: 10}`)->S.parseOrThrow(Main.blockRangeSchema)).toThrow()
  })

  it("rejects non-int _gte", t => {
    t.expect(() => %raw(`{_gte: "10"}`)->S.parseOrThrow(Main.blockRangeSchema)).toThrow()
  })

  it("rejects _every: 0 (would crash the modulo math downstream)", t => {
    t.expect(() => %raw(`{_every: 0}`)->S.parseOrThrow(Main.blockRangeSchema)).toThrow()
  })

  it("rejects negative _every", t => {
    t.expect(() => %raw(`{_every: -1}`)->S.parseOrThrow(Main.blockRangeSchema)).toThrow()
  })

  it("accepts _every: 1 (the minimum / default)", t => {
    let parsed = %raw(`{_every: 1}`)->S.parseOrThrow(Main.blockRangeSchema)
    t.expect(parsed).toEqual(({_gte: None, _lte: None, _every: 1}: Main.blockRange))
  })
})

describe("Evm ecosystem onBlockFilterSchema", () => {
  let schema = Evm.ecosystem.onBlockFilterSchema

  it("surfaces the inner range chunk as Some(unknown) when block.number is present", t => {
    let parsed =
      %raw(`{block: {number: {_gte: 10, _every: 2}}}`)->S.parseOrThrow(schema)
    // Feed the inner chunk through the shared range schema (mirrors
    // `extractRange` in Main.res) to prove it carries the raw payload.
    let range = parsed->Option.getExn->S.parseOrThrow(Main.blockRangeSchema)
    t.expect(range).toEqual(({_gte: Some(10), _lte: None, _every: 2}: Main.blockRange))
  })

  it("returns None when `block` is missing entirely", t => {
    let parsed = %raw(`{}`)->S.parseOrThrow(schema)
    t.expect(parsed).toEqual(None)
  })

  it("returns None when `block` is explicitly undefined", t => {
    let parsed = %raw(`{block: undefined}`)->S.parseOrThrow(schema)
    t.expect(parsed).toEqual(None)
  })

  it("chained parse rejects `{block: {}}` at the inner range schema", t => {
    // Semantic change from the old unwrap: `{block: {}}` used to be
    // silently treated as 'no filter'. The outer schema surfaces
    // `Some(undefined)` for this input, and then feeding that through
    // `blockRangeSchema` (what `extractRange` does in Main.res) throws.
    // Net effect: the user gets a clear parse error instead of a silent
    // no-filter registration.
    let parsed = %raw(`{block: {}}`)->S.parseOrThrow(schema)
    t.expect(() =>
      parsed->Option.getExn->S.parseOrThrow(Main.blockRangeSchema)->ignore
    ).toThrow()
  })
})

describe("Fuel ecosystem onBlockFilterSchema", () => {
  let schema = Fuel.ecosystem.onBlockFilterSchema

  it("surfaces the inner range chunk from block.height", t => {
    let parsed =
      %raw(`{block: {height: {_gte: 1, _lte: 100}}}`)->S.parseOrThrow(schema)
    let range = parsed->Option.getExn->S.parseOrThrow(Main.blockRangeSchema)
    t.expect(range).toEqual(({_gte: Some(1), _lte: Some(100), _every: 1}: Main.blockRange))
  })

  it("returns None when `block` is missing", t => {
    let parsed = %raw(`{}`)->S.parseOrThrow(schema)
    t.expect(parsed).toEqual(None)
  })
})

describe("Svm ecosystem onBlockFilterSchema", () => {
  let schema = Svm.ecosystem.onBlockFilterSchema

  it("surfaces the inner range chunk from the flat `slot` key", t => {
    let parsed = %raw(`{slot: {_gte: 42, _every: 3}}`)->S.parseOrThrow(schema)
    let range = parsed->Option.getExn->S.parseOrThrow(Main.blockRangeSchema)
    t.expect(range).toEqual(({_gte: Some(42), _lte: None, _every: 3}: Main.blockRange))
  })

  it("returns None when `slot` is omitted (no inner object layer)", t => {
    let parsed = %raw(`{}`)->S.parseOrThrow(schema)
    t.expect(parsed).toEqual(None)
  })

  it("returns None when `slot` is explicitly undefined", t => {
    let parsed = %raw(`{slot: undefined}`)->S.parseOrThrow(schema)
    t.expect(parsed).toEqual(None)
  })
})

describe("Ecosystem.t wires the correct onBlockMethodName", () => {
  it("EVM exposes onBlock", t => {
    t.expect(Evm.ecosystem.onBlockMethodName).toBe("onBlock")
  })
  it("Fuel exposes onBlock", t => {
    t.expect(Fuel.ecosystem.onBlockMethodName).toBe("onBlock")
  })
  it("SVM exposes onSlot", t => {
    t.expect(Svm.ecosystem.onBlockMethodName).toBe("onSlot")
  })
})
