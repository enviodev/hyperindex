open Vitest

// With transaction handlers on the chain, its transaction rows are rows like
// its events for everything that sizes the buffer: what a range holds, where
// the n-th row sits, how big the buffer is. Without them, they are joins only.

let alice = "0x1111111111111111111111111111111111111111"

let transactionRow = (~blockNumber, ~transactionIndex) =>
  dict{
    "blockNumber": JSON.String(`0x${blockNumber->Int.toString(~radix=16)}`),
    "transactionIndex": JSON.String(`0x${transactionIndex->Int.toString(~radix=16)}`),
    "hash": JSON.String(SimulateItems.defaultTransactionHash(~blockNumber, ~transactionIndex)),
    "from": JSON.String(alice),
  }

let onTransactionRegistration: Internal.onTransactionRegistration = {
  index: 0,
  name: "sends",
  chainId: 1->ChainId.fromInt,
  filter: {from: [alice]},
  transactionFieldMask: 0.,
  blockFieldMask: 0.,
  handler: _ => Promise.resolve(),
}

let sizes = (~onTransactionRegistrations) => {
  let buffer = ChainBuffer.makeForChain(
    ~ecosystem=Evm,
    ~onEventRegistrations=[],
    ~onBlockRegistrations=[],
    ~onTransactionRegistrations,
    ~shouldChecksum=false,
    ~addressStore=TestAddresses.storeOf(~contracts=[], ~addresses=[]),
  )
  buffer
  ->ChainBuffer.mergePage(
    BufferPage.fromEvmJs(
      ~transactions=[
        transactionRow(~blockNumber=5, ~transactionIndex=0),
        transactionRow(~blockNumber=5, ~transactionIndex=3),
        transactionRow(~blockNumber=9, ~transactionIndex=1),
      ],
      ~blocks=[],
    ),
    ~reorgThreshold=0,
    ~reportOnly=false,
  )
  ->ignore
  (
    buffer->ChainBuffer.countItemsInBlockRange(~fromBlock=0, ~toBlock=10),
    [0, 1, 2, 3]->Array.map(rowOffset =>
      buffer->ChainBuffer.getBlockNumberOfRowAt(~fromBlock=0, ~rowOffset)->Null.toOption
    ),
    buffer->ChainBuffer.rowCount,
  )
}

// The rows a merge reports kept price the next queries. A page bringing
// transactions the buffer already runs handlers on keeps none of them again,
// while one completing a row a log joined does keep it.
let keptAcrossMerges = () => {
  let buffer = ChainBuffer.makeForChain(
    ~ecosystem=Evm,
    ~onEventRegistrations=[],
    ~onBlockRegistrations=[],
    ~onTransactionRegistrations=[onTransactionRegistration],
    ~shouldChecksum=false,
    ~addressStore=TestAddresses.storeOf(~contracts=[], ~addresses=[]),
  )
  let merge = transactions =>
    (
      buffer->ChainBuffer.mergePage(
        BufferPage.fromEvmJs(~transactions, ~blocks=[]),
        ~reorgThreshold=0,
        ~reportOnly=false,
      )
    ).rowsKept
  let joinedOnly = dict{
    "blockNumber": JSON.String("0x7"),
    "transactionIndex": JSON.String("0x0"),
    "hash": JSON.String("0x" ++ String.repeat("ab", 32)),
  }
  [
    merge([transactionRow(~blockNumber=5, ~transactionIndex=0)]),
    merge([transactionRow(~blockNumber=5, ~transactionIndex=0)]),
    merge([joinedOnly]),
    merge([transactionRow(~blockNumber=7, ~transactionIndex=0)]),
  ]
}

describe("A chain buffer's transaction rows", () => {
  it("are kept once however many pages bring them", t => {
    t.expect(keptAcrossMerges()).toEqual([1, 0, 0, 1])
  })

  it("count as rows only on a chain with transaction handlers", t => {
    t.expect((
      sizes(~onTransactionRegistrations=[onTransactionRegistration]),
      sizes(~onTransactionRegistrations=[]),
    )).toEqual(((3, [Some(5), Some(5), Some(9), None], 3), (0, [None, None, None, None], 0)))
  })
})
