open Vitest

// The store takes 32-byte block hashes; widen the short markers these
// fixtures use rather than making every one of them 64 digits long.
let evmHash = hex =>
  "0x" ++ hex->String.slice(~start=2, ~end=hex->String.length)->String.padStart(64, "0")


let chainId = 1->ChainId.fromInt

// Mock source that throws Source.RateLimited on the first N calls, then
// returns Ok with the requested block data. Lets us exercise
// SourceManager.getBlockHashes' rate-limit retry path deterministically
// without depending on a live HyperSync endpoint.
let makeMockSource = (~rateLimitedCalls: int, ~resetMs: int): Source.t => {
  let callCount = ref(0)
  {
    name: "MockHyperSync",
    sourceFor: Sync,
    chainId,
    poweredByHyperSync: true,
    pollingInterval: 100,
    getBlockHashes: (~blockNumbers, ~logger as _) => {
      let current = callCount.contents
      callCount := current + 1
      if current < rateLimitedCalls {
        throw(Source.RateLimited({resetMs: resetMs, requestStats: []}))
      }
      let data = BlockStore.fromJs(
        blockNumbers->Array.map(n => {
          let hashDigits = n->Int.toString
          {
            BlockStore.blockNumber: n,
            blockHash: evmHash(`0x${hashDigits}`),
            blockTimestamp: n,
          }
        }),
        ~ecosystem=Evm,
        ~shouldChecksum=false,
      )
      Promise.resolve({Source.result: Ok(data), requestStats: []})
    },
    getHeightOrThrow: () => Promise.resolve({Source.height: 100, requestStats: []}),
    getItemsOrThrow: (
      ~fromBlock as _,
      ~toBlock as _,
      ~addressSet as _,
      ~knownHeight as _,
      ~partitionId as _,
      ~selection as _,
      ~itemsTarget as _,
      ~retry as _,
      ~logger as _,
    ) => JsError.throwWithMessage("Not used by rate limit test"),
  }
}

describe("SourceManager.getBlockHashes rate limit handling", () => {
  Async.it("calls source.onReorg after an inconsistent hash response", async t => {
    let reorgCalls = ref(0)
    let attempt = ref(0)
    let source: Source.t = {
      ...makeMockSource(~rateLimitedCalls=0, ~resetMs=0),
      getBlockHashes: (~blockNumbers, ~logger as _) => {
        let blockNumber = blockNumbers->Utils.Array.firstUnsafe
        let response = BlockStore.fromJs(
          [{BlockStore.blockNumber, blockHash: evmHash("0x01")}],
          ~ecosystem=Evm,
          ~shouldChecksum=false,
        )
        if attempt.contents === 0 {
          attempt := 1
          let conflictingPage = BlockStore.fromJs(
            [{BlockStore.blockNumber, blockHash: evmHash("0x02")}],
            ~ecosystem=Evm,
            ~shouldChecksum=false,
          )
          response->BlockStore.appendPage(conflictingPage)
        }
        Promise.resolve({Source.result: Ok(response), requestStats: []})
      },
      onReorg: () => reorgCalls := reorgCalls.contents + 1,
    }
    let sourceManager = SourceManager.make(~sources=[source], ~isRealtime=false)

    let _ = await sourceManager->SourceManager.getBlockHashes(
      ~blockNumbers=[1],
      ~isRealtime=false,
    )

    t.expect(reorgCalls.contents).toEqual(1)
  })

  Async.it("recovers after a rate limit and tracks wait time", async t => {
    // 500ms resetMs * 2 rate-limited calls = ~1s minimum total wait
    let source = makeMockSource(~rateLimitedCalls=2, ~resetMs=500)
    let sourceManager = SourceManager.make(
      ~sources=[source],
      ~isRealtime=false,
    )

    let blockNumbers = [100, 101, 102]
    let result = await sourceManager->SourceManager.getBlockHashes(
      ~blockNumbers,
      ~isRealtime=false,
    )

    t.expect(result->BlockStore.getHashedBlockNumbers(~fromBlock=0, ~belowBlock=103)).toEqual(
      blockNumbers,
    )
    t.expect(sourceManager->SourceManager.getRateLimitTimeMs > 900.0).toEqual(true)
  })

  Async.it("succeeds immediately when no rate limit", async t => {
    let source = makeMockSource(~rateLimitedCalls=0, ~resetMs=100)
    let sourceManager = SourceManager.make(
      ~sources=[source],
      ~isRealtime=false,
    )

    let result = await sourceManager->SourceManager.getBlockHashes(
      ~blockNumbers=[1, 2],
      ~isRealtime=false,
    )

    t.expect(result->BlockStore.getHashedBlockNumbers(~fromBlock=0, ~belowBlock=3)).toEqual([1, 2])
    t.expect(sourceManager->SourceManager.getRateLimitTimeMs).toEqual(0.0)
  })

  Async.it(
    "concurrent rate-limited calls only count the overlapping wall-clock window once",
    async t => {
      let source = makeMockSource(~rateLimitedCalls=4, ~resetMs=500)
      let sourceManager = SourceManager.make(
        ~sources=[source],
        ~isRealtime=false,
      )

      // Two parallel calls — each hits 2 rate limits at ~500ms each.
      // Sequential accounting would yield ~4 * 500ms = 2000ms; the dedup'd
      // wall-clock total should be roughly half that (~1000ms).
      let start = Date.now()
      let _ =
        await [
          sourceManager->SourceManager.getBlockHashes(~blockNumbers=[1], ~isRealtime=false),
          sourceManager->SourceManager.getBlockHashes(~blockNumbers=[2], ~isRealtime=false),
        ]->Promise.all
      let elapsed = Date.now() -. start

      let rateLimitTime = sourceManager->SourceManager.getRateLimitTimeMs
      t.expect(rateLimitTime > 400.0 && rateLimitTime < elapsed +. 100.0).toEqual(true)
    },
  )
})
