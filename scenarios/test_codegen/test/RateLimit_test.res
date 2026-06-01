open Vitest

let rateLimitedApiToken = "3dc856dd-b0ea-494f-b27e-017b8b6b7e07"

let chain = ChainMap.Chain.makeUnsafe(~chainId=1)

let makeHyperSyncSource = (~client: HyperSyncClient.t): Source.t => {
  name: "HyperSync",
  sourceFor: Sync,
  chain,
  poweredByHyperSync: true,
  pollingInterval: 100,
  getBlockHashes: (~blockNumbers, ~logger) =>
    HyperSync.queryBlockDataMulti(
      ~client,
      ~blockNumbers,
      ~sourceName="HyperSync",
      ~chainId=1,
      ~logger,
    )->Promise.thenResolve(HyperSync.mapExn),
  getHeightOrThrow: async () => {
    let query: HyperSyncClient.QueryTypes.query = {
      fromBlock: 0,
      toBlockExclusive: 1,
      fieldSelection: {block: [Number]},
      includeAllBlocks: true,
    }
    let res = await client.get(~query)
    res.archiveHeight->Option.getOr(0)
  },
  getItemsOrThrow: (~fromBlock as _, ~toBlock as _, ~addressesByContractName as _, ~indexingAddresses as _, ~knownHeight as _, ~partitionId as _, ~selection as _, ~retry as _, ~logger as _) =>
    JsError.throwWithMessage("Not implemented for rate limit test"),
}

describe("SourceManager rate limit handling with real HyperSync client", () => {
  Async.it(
    "getBlockHashes recovers from rate limit and tracks wait time",
    async t => {
      let client = HyperSyncClient.make(
        ~url="https://1.hypersync.xyz",
        ~apiToken=rateLimitedApiToken,
        ~maxNumRetries=0,
        ~httpReqTimeoutMillis=120_000,
        ~eventParams=[],
      )

      let source = makeHyperSyncSource(~client)
      let sourceManager = SourceManager.make(
        ~sources=[source],
        ~maxPartitionConcurrency=1,
        ~isRealtime=false,
      )

      let blockNumbers = [20_000_000, 20_000_001, 20_000_002]

      // Burn through the rate limit (10 req/min budget) as fast as possible.
      // 11+ calls in parallel guarantees we exhaust the bucket and trigger 429s.
      let _ =
        await Belt.Array.range(0, 14)
        ->Array.map(_ =>
          sourceManager->SourceManager.getBlockHashes(~blockNumbers, ~isRealtime=false)
        )
        ->Promise.all

      // After parallel storm above, the final call should have waited through
      // at least one rate limit window and returned successfully.
      t.expect(sourceManager->SourceManager.getRateLimitTimeMs > 0.0).toEqual(true)
    },
    ~timeout=240_000,
  )
})
