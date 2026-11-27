open Vitest

// A sparse first range seeds a low processing density. Then a batch is held
// mid-processing while a dense range lands behind it, so the only signal that
// the chain got dense is the ready part of the buffer.
let scenario = Scenario.make(
  ~configYaml=`
name: fetch-state-ready-buffer-density
rollback_on_reorg: false
contracts:
  - name: Token
    events:
      - event: Transfer()
chains:
  - id: 1
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 1
    max_reorg_depth: 0
    contracts:
      - name: Token
        address: "0x0000000000000000000000000000000000000001"
`,
  ~handlers=`
import { indexer } from "envio";

indexer.onEvent({ contract: "Token", event: "Transfer" }, async () => {});
`,
)

let itemsAt = (~fromBlock, ~count): array<MockSource.itemMock> =>
  Array.fromInitializer(~length=count, index => {
    MockSource.blockNumber: fromBlock + index / 5,
    logIndex: index,
  })

describe("Query sizing from the ready buffer", () => {
  scenario->Scenario.it(
    "sizes the next query by the ready buffer's density over the blocks past the batch in flight",
    ~sources=[{chain: 1}],
    ~targetBufferSize=1000,
    async (~t, ~indexer, ~source) => {
      let mock = source(1)
      mock.resolveGetHeightOrThrow(1_000_000)
      await mock.expectItemsQueries([
        {
          fromBlock: 1,
          reply: Respond({items: itemsAt(~fromBlock=10, ~count=1), latestFetchedBlockNumber: 1000}),
        },
      ])
      await indexer.waitUntilIdle()

      let holdProcessing = MockSource.Gate.make()
      await mock.expectItemsQueries([
        {
          fromBlock: 1001,
          reply: Respond({
            items: [{blockNumber: 1001, logIndex: 0, handler: _ => holdProcessing.wait()}],
            latestFetchedBlockNumber: 20000,
          }),
        },
      ])
      // Real time: handlers run off the clock.
      await Scenario.waitUntil(
        () => holdProcessing.entered.contents > 0,
        ~message="the batch up to block 20000 to hold processing",
      )
      await mock.expectItemsQueries([{reply: LeavePending}])
      let seen = mock.pendingItemsQueries->Array.copy
      // 500 items over blocks 20001..20100, five a block.
      await mock.expectItemsQueries([
        {
          fromBlock: 20001,
          reply: Respond({
            items: itemsAt(~fromBlock=20001, ~count=500),
          }),
        },
      ])
      await indexer.advanceTime(0)
      let afterDenseRange =
        mock
        ->MockSource.takeNewPendingItemsQueries(~seen)
        ->Array.map(query => (query.fromBlock, query.toBlock))
      holdProcessing.release()
      await indexer.waitUntilIdle()

      // 500 ready items over the 1800 blocks past the batch in flight put the
      // target inside the chunks already in flight. The processing density, or
      // the same items spread from the committed block at 1000, would read the
      // chain as sparse and send another chunk past them.
      t.expect(afterDenseRange).toEqual([])
    },
  )
})
