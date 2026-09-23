open Vitest

let mockEvent = (
  ~blockNumber,
  ~logIndex=0,
  ~registrationIndex=0,
  ~orderPath=?,
): Internal.item => Internal.Event({
  chainId: 1->ChainId.fromInt,
  blockNumber,
  onEventRegistration: Utils.magic({"index": registrationIndex}),
  logIndex,
  ?orderPath,
  transactionIndex: 0,
  payload: "Mock event in item buffer test"->(Utils.magic: string => Internal.eventPayload),
})

let mockBlockItem = (~blockNumber, ~registrationIndex=0): Internal.item => Internal.Block({
  blockNumber,
  onBlockRegistration: Utils.magic({"index": registrationIndex}),
})

let insertInto = (buffer, items) => {
  buffer->ItemBuffer.insert(items)
  buffer
}

describe("ItemBuffer.insert", () => {
  it("merges an unsorted response into the sorted buffer and drops duplicates", t => {
    let buffer =
      ItemBuffer.fromItems([
        mockEvent(~blockNumber=1),
        mockEvent(~blockNumber=3),
        mockEvent(~blockNumber=5),
      ])->insertInto([
        mockEvent(~blockNumber=4),
        mockEvent(~blockNumber=2),
        mockEvent(~blockNumber=3), // duplicate of the buffer's block 3
        mockEvent(~blockNumber=4), // duplicate within the response
      ])
    t.expect(buffer->ItemBuffer.toArray).toEqual([
      mockEvent(~blockNumber=1),
      mockEvent(~blockNumber=2),
      mockEvent(~blockNumber=3),
      mockEvent(~blockNumber=4),
      mockEvent(~blockNumber=5),
    ])
  })

  it("keeps the buffered item over an equal one delivered again", t => {
    let buffered = mockEvent(~blockNumber=3)
    let redelivered = mockEvent(~blockNumber=3)
    let buffer = ItemBuffer.fromItems([buffered])->insertInto([redelivered])
    t.expect(buffer->ItemBuffer.toArray->Array.getUnsafe(0) === buffered).toBe(true)
  })

  it("keeps two registrations for one log (equal block+logIndex, distinct index)", t => {
    let buffer = ItemBuffer.fromItems([
      mockEvent(~blockNumber=7, ~logIndex=2, ~registrationIndex=1),
      mockEvent(~blockNumber=7, ~logIndex=2, ~registrationIndex=0),
    ])
    t.expect(buffer->ItemBuffer.toArray).toEqual([
      mockEvent(~blockNumber=7, ~logIndex=2, ~registrationIndex=0),
      mockEvent(~blockNumber=7, ~logIndex=2, ~registrationIndex=1),
    ])
  })

  it("runs a block item after every event of its block, whatever the log index", t => {
    // The item kind separates the two runs, so no log index can leapfrog the
    // block handler. SVM keys instructions by transaction index, which climbs
    // far past anything an EVM log index reaches.
    let event = mockEvent(~blockNumber=7, ~logIndex=1_500)
    let blockItem = mockBlockItem(~blockNumber=7)
    t.expect(ItemBuffer.fromItems([blockItem, event])->ItemBuffer.toArray).toEqual([
      event,
      blockItem,
    ])
  })

  it("orders block items of one block by registration", t => {
    let first = mockBlockItem(~blockNumber=7, ~registrationIndex=0)
    let second = mockBlockItem(~blockNumber=7, ~registrationIndex=1)
    t.expect(ItemBuffer.fromItems([second, first, second])->ItemBuffer.toArray).toEqual([
      first,
      second,
    ])
  })

  it("keeps a deep call and a later transaction's call distinct", t => {
    // Guards the pair that a packed key would conflate: folding the path into
    // the transaction's stride makes `tx 0, path [0,0,0]` and `tx 16, path
    // [0,0]` one key, and the merge would drop one of them.
    let deepInFirstTx = mockEvent(~blockNumber=7, ~logIndex=0, ~orderPath=[0, 0, 0])
    let innerInLaterTx = mockEvent(~blockNumber=7, ~logIndex=16, ~orderPath=[0, 0])
    t.expect(ItemBuffer.fromItems([innerInLaterTx, deepInFirstTx])->ItemBuffer.toArray).toEqual([
      deepInFirstTx,
      innerInLaterTx,
    ])
  })

  it("orders sibling calls of one transaction by path, and dedupes an exact repeat", t => {
    let outer = mockEvent(~blockNumber=7, ~logIndex=3, ~orderPath=[1])
    let inner = mockEvent(~blockNumber=7, ~logIndex=3, ~orderPath=[1, 0])
    let nextOuter = mockEvent(~blockNumber=7, ~logIndex=3, ~orderPath=[2])
    t.expect(ItemBuffer.fromItems([nextOuter, inner, outer, inner])->ItemBuffer.toArray).toEqual([
      outer,
      inner,
      nextOuter,
    ])
  })
})

describe("ItemBuffer reads", () => {
  it("counts ready items and extends a batch to the end of its last block", t => {
    let buffer = ItemBuffer.fromItems([
      mockEvent(~blockNumber=1),
      mockEvent(~blockNumber=2),
      mockEvent(~blockNumber=2, ~logIndex=1),
      mockEvent(~blockNumber=2, ~logIndex=2),
      mockEvent(~blockNumber=3),
      mockEvent(~blockNumber=9),
    ])
    t.expect({
      "length": buffer->ItemBuffer.length,
      "readyCount": buffer->ItemBuffer.readyCount(~frontier=3),
      "batchOfTwo": buffer->ItemBuffer.readyItemsCount(~targetSize=2, ~fromItem=0, ~frontier=3),
      "batchPastReady": buffer->ItemBuffer.readyItemsCount(
        ~targetSize=10,
        ~fromItem=0,
        ~frontier=3,
      ),
      "blockAt5": buffer->ItemBuffer.blockNumberAt(5),
      "blockAt6": buffer->ItemBuffer.blockNumberAt(6),
    }).toEqual({
      "length": 6,
      "readyCount": 5,
      "batchOfTwo": 4,
      "batchPastReady": 5,
      "blockAt5": Some(9),
      "blockAt6": None,
    })
  })

  it("counts a log routed to two registrations as one event", t => {
    let buffer = ItemBuffer.fromItems([
      mockEvent(~blockNumber=1, ~registrationIndex=0),
      mockEvent(~blockNumber=1, ~registrationIndex=1),
      mockEvent(~blockNumber=1, ~logIndex=1),
      mockBlockItem(~blockNumber=1),
    ])
    t.expect(buffer->ItemBuffer.newEventFlags(~count=4)).toEqual(Uint8Array.fromArray([1, 0, 1, 1]))
  })
})

describe("ItemBuffer removals", () => {
  it("hands each freed slot to the next item without mixing up items", t => {
    let buffer = ItemBuffer.fromItems([
      mockEvent(~blockNumber=1),
      mockEvent(~blockNumber=2),
      mockEvent(~blockNumber=3),
      mockEvent(~blockNumber=4),
    ])
    buffer->ItemBuffer.consume(~count=1)
    buffer->ItemBuffer.truncateAbove(~blockNumber=2)
    buffer->ItemBuffer.insert([
      mockEvent(~blockNumber=7),
      mockEvent(~blockNumber=5),
      mockEvent(~blockNumber=6),
    ])
    t.expect((buffer->ItemBuffer.peek(~count=2), buffer->ItemBuffer.toArray)).toEqual((
      [mockEvent(~blockNumber=2), mockEvent(~blockNumber=5)],
      [
        mockEvent(~blockNumber=2),
        mockEvent(~blockNumber=5),
        mockEvent(~blockNumber=6),
        mockEvent(~blockNumber=7),
      ],
    ))
  })

  it("releases what it removes so the items can be collected", t => {
    let buffer = ItemBuffer.fromItems([mockEvent(~blockNumber=1), mockEvent(~blockNumber=2)])
    buffer->ItemBuffer.consume(~count=1)
    buffer->ItemBuffer.truncateAbove(~blockNumber=0)
    t.expect(buffer.slots->Array.filter(slot => slot !== Nullable.undefined)).toEqual([])
  })
})

describe("ItemBuffer equality in tests", () => {
  it("compares buffers by the items they hold, in order", t => {
    let reordered = ItemBuffer.fromItems([mockEvent(~blockNumber=1), mockEvent(~blockNumber=2)])
    reordered->ItemBuffer.consume(~count=1)
    reordered->ItemBuffer.insert([mockEvent(~blockNumber=3)])
    t.expect(reordered).toEqual(
      ItemBuffer.fromItems([mockEvent(~blockNumber=2), mockEvent(~blockNumber=3)]),
    )
    t.expect(reordered).not.toEqual(ItemBuffer.fromItems([mockEvent(~blockNumber=2)]))
  })
})
