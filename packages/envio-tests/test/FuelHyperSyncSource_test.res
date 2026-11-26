// A HyperFuel source against a local server answering at the HTTP level: what
// the source manager gets for the statuses the server answers with.
open Vitest

let makeSource = (~url) => {
  let addressStore = TestAddresses.storeOf(~contracts=[], ~ecosystem=Fuel)
  FuelHyperSyncSource.make({
    chainId: 0->ChainId.fromInt,
    endpointUrl: url,
    apiToken: Some(MockHyperSyncServer.apiToken),
    chainBuffer: TestChainBuffer.forChain(~ecosystem=Fuel, ~onEventRegistrations=[], ~addressStore),
    logger: Logger.makeInMemory(),
  })
}

let fetch = (source: Source.t) =>
  source.getItemsOrThrow(
    ~fromBlock=10,
    ~toBlock=Some(11),
    ~addressSet=TestAddresses.storeOf(~contracts=[], ~ecosystem=Fuel)->AddressStore.emptySet,
    ~reorgableFrom=None,
    ~knownHeight=100,
    ~partitionId="mock-partition",
    ~selection={
      dependsOnAddresses: false,
      onEventRegistrations: [],
      onBlockRegistrations: [],
      onTransactionRegistrations: [],
    },
    ~retry=0,
    ~logger=Logger.makeInMemory(),
  )

describe("HyperFuel source responses", () => {
  Async.it("maps a rate-limited response to the wait the manager retries on", async t => {
    let result = await MockHyperSyncServer.withServer(
      ~height=100,
      async server => {
        server->MockHyperSyncServer.pushRawReply({
          status: 429,
          headers: dict{"x-ratelimit-reset": "3", "x-ratelimit-remaining": "0"},
          body: "slow down",
        })
        switch await makeSource(~url=server->MockHyperSyncServer.url)->fetch {
        | _ => "fetched"
        | exception Source.RateLimited({resetMs}) => `rateLimited:${resetMs->Int.toString}`
        | exception Source.GetItemsError(FailedGettingItems({retry: WithBackoff({message})})) =>
          `backoff:${message}`
        }
      },
    )
    t.expect(result).toBe("rateLimited:3000")
  })
})
