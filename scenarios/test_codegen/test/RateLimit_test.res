open Vitest

let chain = ChainMap.Chain.makeUnsafe(~chainId=1)

// Mock source that throws Source.RateLimited on the first N calls, then
// returns Ok with the requested block data. Lets us exercise
// SourceManager.getBlockHashes' rate-limit retry path deterministically
// without depending on a live HyperSync endpoint.
let makeMockSource = (~rateLimitedCalls: int, ~resetMs: int): Source.t => {
  let callCount = ref(0)
  {
    name: "MockHyperSync",
    sourceFor: Sync,
    chain,
    poweredByHyperSync: true,
    pollingInterval: 100,
    getBlockHashes: (~blockNumbers, ~logger as _) => {
      let current = callCount.contents
      callCount := current + 1
      if current < rateLimitedCalls {
        throw(Source.RateLimited({resetMs: resetMs}))
      }
      let data = blockNumbers->Array.map(
        n => {
          ReorgDetection.blockNumber: n,
          blockHash: `0x${n->Int.toString}`,
          blockTimestamp: n,
        },
      )
      Promise.resolve(Ok(data))
    },
    getHeightOrThrow: () => Promise.resolve(100),
    getItemsOrThrow: (
      ~fromBlock as _,
      ~toBlock as _,
      ~addressesByContractName as _,
      ~indexingAddresses as _,
      ~knownHeight as _,
      ~partitionId as _,
      ~selection as _,
      ~retry as _,
      ~logger as _,
    ) => JsError.throwWithMessage("Not used by rate limit test"),
  }
}

describe("SourceManager.getBlockHashes rate limit handling", () => {
  Async.it("recovers after a rate limit and tracks wait time", async t => {
    // Short resetMs so the test completes quickly. SourceManager waits
    // resetMs + 1000ms safety buffer.
    let source = makeMockSource(~rateLimitedCalls=2, ~resetMs=100)
    let sourceManager = SourceManager.make(
      ~sources=[source],
      ~maxPartitionConcurrency=1,
      ~isRealtime=false,
    )

    let blockNumbers = [100, 101, 102]
    let result = await sourceManager->SourceManager.getBlockHashes(
      ~blockNumbers,
      ~isRealtime=false,
    )

    t.expect(result->Array.length).toEqual(3)
    t.expect(result->Array.map(r => r.blockNumber)).toEqual(blockNumbers)
    // Two rate-limit waits at ~1.1s each = ~2.2s minimum
    t.expect(sourceManager->SourceManager.getRateLimitTimeMs > 2000.0).toEqual(true)
  })

  Async.it("succeeds immediately when no rate limit", async t => {
    let source = makeMockSource(~rateLimitedCalls=0, ~resetMs=100)
    let sourceManager = SourceManager.make(
      ~sources=[source],
      ~maxPartitionConcurrency=1,
      ~isRealtime=false,
    )

    let result = await sourceManager->SourceManager.getBlockHashes(
      ~blockNumbers=[1, 2],
      ~isRealtime=false,
    )

    t.expect(result->Array.length).toEqual(2)
    t.expect(sourceManager->SourceManager.getRateLimitTimeMs).toEqual(0.0)
  })

  Async.it(
    "concurrent rate-limited calls only count the overlapping wall-clock window once",
    async t => {
      let source = makeMockSource(~rateLimitedCalls=4, ~resetMs=200)
      let sourceManager = SourceManager.make(
        ~sources=[source],
        ~maxPartitionConcurrency=2,
        ~isRealtime=false,
      )

      // Two parallel calls — each hits 2 rate limits before succeeding.
      // Sequential accounting would yield ~4 * 1.2s = 4.8s; the dedup'd
      // wall-clock total should be roughly half that (~2.4s).
      let start = Date.now()
      let _ =
        await [
          sourceManager->SourceManager.getBlockHashes(~blockNumbers=[1], ~isRealtime=false),
          sourceManager->SourceManager.getBlockHashes(~blockNumbers=[2], ~isRealtime=false),
        ]->Promise.all
      let elapsed = Date.now() -. start

      let rateLimitTime = sourceManager->SourceManager.getRateLimitTimeMs
      t.expect(rateLimitTime > 1000.0 && rateLimitTime < elapsed +. 100.0).toEqual(true)
    },
  )
})
