open Vitest

// A sparse chain freezes at head: with a low events-per-block density, the
// target-block computation `bufferBlockNumber + ceil(chainTargetItems /
// density)` exceeds 2^31 and the float-to-int truncation wraps negative, so
// the target collapses below every partition's cursor and getNextQuery never
// emits a query again. The wait loop keeps finding new blocks (knownHeight
// advances) while the frontier and progress stay frozen — the chain-42161
// incident on 3.5.1.
//
// One event across 30k blocks seeds chainDensity = 1/30000; with the 100k
// buffer target the division is ~3e9, which truncates to a negative int.
describe("Sparse-density target overflow", () => {
  Async.it(
    "keeps fetching new head blocks when the chain density is very low",
    async t => {
      let sourceMock = MockIndexer.Source.make(
        [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes],
        ~chainId=#1337,
        ~pollingInterval=1,
      )
      let indexerMock = await MockIndexer.Indexer.make(
        ~chains=[
          {
            chain: #1337,
            sourceConfig: Config.CustomSources([sourceMock.source]),
            maxReorgDepth: 0,
          },
        ],
        ~shouldRollbackOnReorg=false,
        ~targetBufferSize=100_000,
        ~reducedPollingInterval=1,
      )
      await Utils.delay(0)

      sourceMock.resolveGetHeightOrThrow(30_000)
      await Utils.delay(0)
      await Utils.delay(0)

      // One event over the whole 30k-block range: the batch seeds the chain
      // density at ~1/30000 events per block.
      await MockIndexer.Helper.waitItemsQuery(sourceMock)
      sourceMock.resolveGetItemsOrThrow(
        [{blockNumber: 5, logIndex: 0}],
        ~latestFetchedBlockNumber=30_000,
      )
      await indexerMock.getBatchWritePromise()

      // A new block arrives. The chain is one block behind the head and must
      // query it — on the broken version the wrapped target block leaves every
      // partition out of range and the chain only ever waits.
      let attempts = ref(0)
      while sourceMock.getItemsOrThrowCalls->Array.length === 0 && attempts.contents < 2000 {
        attempts := attempts.contents + 1
        try sourceMock.resolveGetHeightOrThrow(30_001) catch {
        | _ => ()
        }
        await Utils.delay(1)
      }
      t.expect(
        sourceMock.getItemsOrThrowCalls->Array.map(call => call.payload["fromBlock"]),
        ~message="the chain should query the new head block despite its low event density",
      ).toEqual([30_001])

      await indexerMock.stop()
    },
    ~timeout=30_000,
  )
})
