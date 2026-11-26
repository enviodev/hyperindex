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
        let valuesOf = async name => (await indexer.metric(name))->Array.map(({value}) => value)
        t.expect({
          "idle": await valuesOf("envio_indexing_idle_seconds"),
          "waiting": await valuesOf("envio_indexing_source_waiting_seconds"),
          "querying": await valuesOf("envio_indexing_source_querying_seconds"),
        }).toEqual({"idle": ["0"], "waiting": ["0"], "querying": ["1"]})
      },
    )
  })
})
