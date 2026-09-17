open Vitest

// Groundwork for pricing HyperSync by the blocks it returns: the source reports
// what came back per request, and the indexer exposes it per source and method
// so a run can be costed against the requests that produced it.
let scenario = Scenario.make(
  ~configYaml=`
name: response-blocks-metric
rollback_on_reorg: false
chains:
  - id: 1337
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 1
    max_reorg_depth: 0
    contracts:
      - name: Gravatar
        address: "0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3"
        events:
          - event: "TestEvent()"
`,
  ~schema=`
type Gravatar {
  id: ID!
  owner: String!
}
`,
)

describe("Source response block metrics", () => {
  scenario->Scenario.it(
    "Sums the blocks each response carried and counts the responses that carried none",
    ~sources=[{chain: 1337, methods: [#getHeightOrThrow, #getItemsOrThrow], pollingInterval: 1}],
    async (~t, ~indexer, ~source) => {
      let sourceMock = source(1337)

      let samples = async name =>
        (await indexer.metric(name))->Array.map(({value, labels}: IndexerRunner.metric) => (
          labels->Dict.get("method"),
          value,
        ))

      sourceMock.resolveGetHeightOrThrow(100)
      await MockSource.waitItemsQuery(sourceMock)
      sourceMock.resolveGetItemsOrThrow(
        [{blockNumber: 50, logIndex: 0}],
        ~latestFetchedBlockNumber=50,
        ~knownHeight=100,
        ~requestStats=[{Source.method: "getLogs", seconds: 0.5, responseBlocks: 3}],
      )
      await indexer.getBatchWritePromise()

      t.expect(await samples("envio_source_response_blocks_total")).toEqual([
        (Some("getLogs"), "3"),
      ])
      t.expect(
        await samples("envio_source_response_empty_total"),
        ~message="a method that reports blocks reports its empty responses from the first request on",
      ).toEqual([(Some("getLogs"), "0")])

      // A range the source scanned and matched nothing in. It costs a request
      // like any other, and under a per-block price it is the one billed at
      // nothing.
      await MockSource.waitItemsQuery(sourceMock)
      sourceMock.resolveGetItemsOrThrow(
        [],
        ~latestFetchedBlockNumber=100,
        ~knownHeight=100,
        ~requestStats=[{Source.method: "getLogs", seconds: 0.25, responseBlocks: 0}],
      )
      await Utils.delay(0)

      t.expect(await samples("envio_source_response_blocks_total")).toEqual([
        (Some("getLogs"), "3"),
      ])
      t.expect(await samples("envio_source_response_empty_total")).toEqual([
        (Some("getLogs"), "1"),
      ])
    },
  )
})
