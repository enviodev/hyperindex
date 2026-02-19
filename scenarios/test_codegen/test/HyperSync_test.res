open Vitest

let testApiToken = "3dc856dd-b0ea-494f-b27e-017b8b6b7e07"

describe_skip("Test Hyperliquid broken transaction response", () => {
  Async.it("should handle broken transaction response", async () => {
    let page = await HyperSync.GetLogs.query(
      ~client=HyperSyncClient.make(
        ~url="https://645749.hypersync.xyz",
        ~apiToken=testApiToken,
        ~maxNumRetries=Env.hyperSyncClientMaxRetries,
        ~httpReqTimeoutMillis=Env.hyperSyncClientTimeoutMillis,
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
      ~nonOptionalBlockFieldNames=[],
      ~nonOptionalTransactionFieldNames=["hash"],
    )

    Js.log(page)
  })
})
