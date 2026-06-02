open Vitest

let testApiToken =
  Env.envioApiToken->Option.getOrThrow(
    ~message="ENVIO_API_TOKEN env var must be set to run HyperSync tests",
  )

describe_skip("Test Hyperliquid broken transaction response", () => {
  Async.it("should handle broken transaction response", async _t => {
    let page = await HyperSync.GetLogs.query(
      ~client=HyperSyncClient.make(
        ~url="https://645749.hypersync.xyz",
        ~apiToken=testApiToken,
        ~maxNumRetries=0,
        ~httpReqTimeoutMillis=Env.hyperSyncClientTimeoutMillis,
        ~eventParams=[],
      ),
      ~fromBlock=12403138,
      ~toBlock=Some(12403139),
      ~logSelections=[
        {
          addresses: [],
          topicSelections: [
            {
              topic0: [
                "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"->EvmTypes.Hex.fromStringUnsafe,
              ],
              topic1: [],
              topic2: [],
              topic3: [],
            },
          ],
        },
      ],
      ~fieldSelection={
        log: [Address, Data, LogIndex, Topic0, Topic1, Topic2, Topic3],
        transaction: [Hash],
      },
    )

    Console.log(page)
  })
})
