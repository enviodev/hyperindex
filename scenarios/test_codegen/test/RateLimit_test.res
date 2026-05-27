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
      )

      let source = makeHyperSyncSource(~client)
      let sourceManager = SourceManager.make(
        ~sources=[source],
        ~maxPartitionConcurrency=1,
        ~isRealtime=false,
      )

      let blockNumbers = [20_000_000, 20_000_001, 20_000_002]

      // Exhaust the rate limit (10 req/min budget)
      for _ in 0 to 10 {
        let _ = await sourceManager->SourceManager.getBlockHashes(
          ~blockNumbers,
          ~isRealtime=false,
        )
      }

      // This call will hit rate limit, wait, retry, and succeed
      let result = await sourceManager->SourceManager.getBlockHashes(
        ~blockNumbers,
        ~isRealtime=false,
      )

      t.expect(result->Array.length).toEqual(3)
      t.expect(result->Array.map(r => r.blockNumber)).toEqual(blockNumbers)
      t.expect(sourceManager->SourceManager.getRateLimitTimeMs > 0.0).toEqual(true)
    },
    ~timeout=180_000,
  )
})
