open Vitest

let chainId = 1->ChainId.fromInt

let registration = {
  "index": 0,
  "fieldSelection": {"transactionMask": 0., "blockMask": 0.},
}->(Utils.magic: {..} => Internal.onEventRegistration)

let context: StoredItems.context = {
  chainId,
  ecosystem: Evm,
  onEventRegistrations: [registration],
  onBlockRegistrations: [],
  onTransactionRegistrations: [],
}

let eventWithPayload = (payload: dict<unknown>): Internal.item => Internal.Event({
  chainId,
  blockNumber: 1,
  logIndex: 0,
  transactionIndex: 0,
  onEventRegistration: registration,
  payload: payload->(Utils.magic: dict<unknown> => Internal.eventPayload),
})

describe("BufferPage.fromItems", () => {
  Async.it("keeps every kind of value a simulated payload holds", async t => {
    let payload = dict{
      "zero": 0n->(Utils.magic: bigint => unknown),
      "negative": -5n->(Utils.magic: bigint => unknown),
      "uint256Max": 115792089237316195423570985008687907853269984665640564039457584007913129639935n->(
        Utils.magic: bigint => unknown
      ),
      "bytes": Uint8Array.fromArray([1, 2, 255])->(Utils.magic: Uint8Array.t => unknown),
      "nested": {"list": [1, 2], "missing": Nullable.null, "flag": true}->(
        Utils.magic: {"list": array<int>, "missing": Nullable.t<int>, "flag": bool} => unknown
      ),
      "absent": %raw(`undefined`),
      "text": "0xabc"->(Utils.magic: string => unknown),
    }
    let taken = await TestChainBuffer.pageOf([
      eventWithPayload(payload->Dict.copy),
    ])->TestChainBuffer.buildAll(
      ~buffer=TestChainBuffer.decodedBuffer(~onEventRegistrations=[registration]),
      ~context,
    )

    // A payload without its own transaction and block reads them from the
    // chain's buffer; with no field selected, each is an empty object, and the
    // transaction carries the block.
    payload->Dict.set("transaction", %raw(`{"block": {}}`))
    payload->Dict.set("block", %raw(`{}`))
    t.expect(taken).toEqual([eventWithPayload(payload)])
  })

  it("refuses an object that isn't plain data instead of storing its keys alone", t => {
    let withDate = dict{"at": Date.fromTime(0.)->(Utils.magic: Date.t => unknown)}

    t->toThrowErrorEqual(
      () => TestChainBuffer.pageOf([eventWithPayload(withDate)]),
      "a class instance (an object whose prototype isn't Object.prototype, such as a Date or Map) can't be stored as a JS value tape on DecodedEventInput.item",
    )
  })

  it("refuses a bigint wider than 256 bits instead of storing it truncated", t => {
    let tooWide = dict{
      "value": 115792089237316195423570985008687907853269984665640564039457584007913129639936n->(
        Utils.magic: bigint => unknown
      ),
    }

    t->toThrowErrorEqual(
      () => TestChainBuffer.pageOf([eventWithPayload(tooWide)]),
      "a bigint wider than 256 bits can't be stored as a JS value tape on DecodedEventInput.item",
    )
  })
})
