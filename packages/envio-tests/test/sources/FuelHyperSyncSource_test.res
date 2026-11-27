open Vitest

// A HyperFuel source against a local server answering at the HTTP level: what
// the source manager gets for the statuses the server answers with.

let fetch = (source: Source.t, ~addressing) =>
  source.getItems(
    ~request=TestSources.request(
      ~fromBlock=10,
      ~toBlock=11,
      ~addressStore=addressing->Pair.first,
      ~contractNames=addressing->Pair.second,
    ),
    ~toBlock=Some(11),
    ~retry=0,
    ~reorgableFrom=None,
    ~knownHeight=100,
  )

describe("HyperFuel source responses", () => {
  Async.it("maps a rate-limited response to the wait the manager retries on", async t => {
    let result = await MockHyperSyncServer.withServer(
      ~height=100,
      async server => {
        let addressStore = TestAddresses.storeOf(~contracts=[], ~ecosystem=Fuel)
        let source = TestSources.hyperSync(
          ~url=server->MockHyperSyncServer.url,
          ~ecosystem=Fuel,
          ~chainBuffer=TestChainBuffer.forChain(
            ~ecosystem=Fuel,
            ~onEventRegistrations=[],
            ~addressStore,
          ),
        )
        server->MockHyperSyncServer.pushRawReply({
          status: 429,
          headers: dict{"x-ratelimit-reset": "3", "x-ratelimit-remaining": "0"},
          body: "slow down",
        })
        (await source->fetch(~addressing=(addressStore, []))).result->Result.map(
          ({latestFetchedBlockNumber}) => latestFetchedBlockNumber,
        )
      },
    )
    t.expect(result).toEqual(Error(RateLimited({resetMs: 3000})))
  })
})
