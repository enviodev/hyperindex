open Vitest

let scenario = Scenario.make(
  ~configYaml=`
name: preload-handler-metrics
contracts:
  - name: Token
    events:
      - event: Transfer()
chains:
  - id: 1
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 1
    contracts:
      - name: Token
        address: "0x0000000000000000000000000000000000000001"
`,
)

describe("preload handler metrics", () => {
  // A preload run is expected to throw now and then, eg on an entity an
  // earlier event of the batch creates. It must still close its timing: one
  // left open keeps the handler's preload time from ever accruing again.
  Async.it("count and time a preload run that throws", async t => {
    await scenario->Scenario.run(
      ~sources=[{chain: 1}],
      async (~indexer, ~source) => {
        let mock = source(1)
        mock.resolveGetHeightOrThrow(300)
        await mock.expectItemsQueries([
          {
            reply: Respond({
              items: [
                {
                  blockNumber: 5,
                  logIndex: 1,
                  preloadHandler: async _ => JsError.throwWithMessage("Not created yet"),
                },
                {blockNumber: 6, logIndex: 2, preloadHandler: async _ => await indexer.delay(5)},
              ],
              latestFetchedBlockNumber: 100,
            }),
          },
        ])
        await indexer.advanceTime(5)
        await indexer.getBatchWritePromise()
        let valueOf = async name =>
          switch await indexer.metric(name) {
          | [{value}] => value
          | samples => `${samples->Array.length->Int.toString} samples`
          }
        t.expect({
          "runs": await valueOf("envio_preload_handler_total"),
          "seconds": await valueOf("envio_preload_handler_seconds"),
          "secondsTotal": await valueOf("envio_preload_handler_seconds_total"),
        }).toEqual({"runs": "2", "seconds": "0.005", "secondsTotal": "0.005"})
      },
    )
  })
})
