open Vitest

let scenario = Scenario.make(
  ~configYaml=`
name: parse-seconds-metric
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

describe("envio_fetching_block_range_parse_seconds", () => {
  // Sources hand back rows, and a batch builds its handler events from them.
  // That build is the cost the parse metric reports.
  Async.it("accrues the time a batch spends building its events", async t => {
    await scenario->Scenario.run(
      ~sources=[{chain: 1}],
      async (~indexer, ~source) => {
        let mock = source(1)
        mock.resolveGetHeightOrThrow(300)
        await mock.expectItemsQueries([
          {
            reply: Respond({
              // Enough rows for the build to register at the metric's
              // millisecond precision.
              items: Array.fromInitializer(
                ~length=20_000,
                index => {
                  MockSource.blockNumber: 5 + index / 250,
                  logIndex: mod(index, 250),
                },
              ),
              latestFetchedBlockNumber: 100,
            }),
          },
        ])
        await indexer.getBatchWritePromise()
        t.expect(
          (await indexer.metric("envio_fetching_block_range_parse_seconds"))->Array.map(
            ({labels, value}: IndexerRunner.metric) => (labels, value->Float.parseFloat > 0.),
          ),
        ).toEqual([(Dict.fromArray([("chainId", "1")]), true)])
      },
    )
  })
})
