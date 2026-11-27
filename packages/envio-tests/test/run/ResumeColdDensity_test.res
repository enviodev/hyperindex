open Vitest

// The chain's one event is rolled back and the chain goes on past it with no
// other, so it resumes with a first event block behind its progress and no
// events processed: nothing to measure a density from.
let scenario = Scenario.make(
  ~configYaml=`
name: resume-cold-density
rollback_on_reorg: true
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
    max_reorg_depth: 199
    contracts:
      - name: Token
        address: "0x0000000000000000000000000000000000000001"
`,
  ~handlers=`
import { indexer } from "envio";

indexer.onEvent({ contract: "Token", event: "Transfer" }, async () => {});
`,
)

describe("A resumed chain with no events processed", () => {
  scenario->Scenario.it(
    "probes cold, with one admission unit of the pool",
    ~sources=[{chain: 1, methods: [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes]}],
    ~targetBufferSize=1000,
    async (~t, ~indexer, ~source) => {
      let mock = source(1)
      await Scenario.enterReorgThreshold(~indexer, ~source=mock)
      await mock.expectItemsQueries([
        {
          fromBlock: 101,
          reply: Respond({items: [{blockNumber: 200, logIndex: 0}], latestFetchedBlockNumber: 300}),
        },
      ])
      await indexer.getBatchWritePromise()
      await indexer.waitUntilIdle()
      await Scenario.reorgAbove(~indexer, ~source=mock, ~head=300, ~validUpTo=150)

      let restarted = await indexer.restart()
      mock.resolveGetHeightOrThrow(100_000)
      await mock.expectItemsQueries([{reply: LeavePending}])
      await restarted.waitUntilIdle()

      t.expect((
        (await restarted.queryChains())->Array.map(
          chain => (chain.firstEventBlock, chain.progressBlock),
        ),
        mock.pendingItemsQueries->Array.map(
          query => (
            query.fromBlock,
            restarted->QueryReservations.probeReservation(~fromBlock=query.fromBlock),
          ),
        ),
      )).toEqual(([(Some(200), 301)], [(302, Some(100))]))
    },
  )
})
