open Vitest

let scenario = Scenario.make(
  ~configYaml=`
name: source-status-metrics
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

describe("source status metrics", () => {
  Async.it("time a query in flight by the run's clock", async t => {
    await scenario->Scenario.run(
      ~sources=[{chain: 1}],
      async (~indexer, ~source) => {
        let mock = source(1)
        mock.resolveGetHeightOrThrow(300)
        await mock.expectItemsQueries([{fromBlock: 1, reply: LeavePending}])
        await indexer.advanceTime(1000)
        let valueOf = async name =>
          switch await indexer.metric(name) {
          | [{value}] => value
          | samples => `${samples->Array.length->Int.toString} samples`
          }
        t.expect({
          "idle": await valueOf("envio_indexing_idle_seconds"),
          "waiting": await valueOf("envio_indexing_source_waiting_seconds"),
          "querying": await valueOf("envio_indexing_source_querying_seconds"),
        }).toEqual({"idle": "0", "waiting": "0", "querying": "1"})
      },
    )
  })
})
