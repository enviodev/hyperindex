open Vitest

let testApiToken =
  Env.envioApiToken->Option.getOrThrow(
    ~message="ENVIO_API_TOKEN env var must be set to run HyperSync tests",
  )

// Wildcard-only selection, so the store holds nothing and the partition's set
// is empty.
let addressStore = AddressStore.make(
  ~ecosystem=Ecosystem.Evm,
  ~contracts=[{name: "ERC20", startBlock: None, dependsOnAddresses: true}],
)

describe_skip("Test Hyperliquid broken transaction response", () => {
  Async.it("should handle broken transaction response", async _t => {
    let transferSighash = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"
    let page = await HyperSync.GetItems.query(
      ~client=HyperSyncClient.make(
        ~url="https://645749.hypersync.xyz",
        ~apiToken=testApiToken,
        ~httpReqTimeoutMillis=Env.hyperSyncClientTimeoutMillis,
        ~eventRegistrations=[
          {
            index: 0,
            sighash: Some(transferSighash),
            topicCount: 3,
            eventName: "Transfer",
            contractName: "ERC20",
            isWildcard: true,
            dependsOnAddresses: false,
            startBlock: None,
            params: [],
            topicFilters: [
              {
                topic0: Some([transferSighash]),
                topic1: Some([]),
                topic2: Some([]),
                topic3: Some([]),
              },
            ],
            blockFields: [],
            transactionFields: ["Hash"],
          },
        ],
        ~addressStore,
      ),
      ~query={
        fromBlock: 12403138,
        toBlock: Some(12403139),
        maxNumLogs: 5000,
        onEventRegistrationIndexes: [0],
        onBlockRegistrationIndexes: [],
        clientFilteredContracts: None,
      },
      ~addressSet=addressStore->AddressStore.emptySet,
    )

    Console.log(page)
  })
})
