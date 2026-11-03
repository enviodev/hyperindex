open Vitest

let makeConfigYaml = (~chainOptions="") =>
  `
name: block-throttle
chains:
  - id: 1337
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 1
    max_reorg_depth: 200
    block_throttle: 5${chainOptions}
    contracts:
      - name: Gravatar
        address: "0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3"
        events:
          - event: "TestEvent()"
`

let schema = `
type Gravatar {
  id: ID!
  owner: String!
}
`

let scenario = Scenario.make(~configYaml=makeConfigYaml(), ~schema)

let scenarioWithEndBlock = Scenario.make(
  ~configYaml=makeConfigYaml(~chainOptions="\n    end_block: 303"),
  ~schema,
)

let scenarioWithOnBlock = Scenario.make(
  ~configYaml=makeConfigYaml(),
  ~schema,
  ~handlers=`
import { indexer } from "envio";

indexer.onBlock({ name: "everyBlock" }, async () => {});
`,
)

let methods = [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes]

let upTo = (~knownHeight=?, toBlock) => MockSource.Respond({
  items: [],
  latestFetchedBlockNumber: toBlock,
  ?knownHeight,
})

// Leaves the chain fetched to 300, the head it knows.
let fetchToHead = async (~indexer: IndexerRunner.t, ~source: MockSource.t, ~knownHeight=?) => {
  await Scenario.enterReorgThreshold(~indexer, ~source)
  source.resolveGetHeightOrThrow(300)
  await source.expectItemsQueries([{fromBlock: 101, reply: upTo(300, ~knownHeight?)}])
  await indexer.getBatchWritePromise()
}

let chainMetric = async (indexer: IndexerRunner.t, name) =>
  (await indexer.metric(name))->Array.map(({value}) => value)

describe("E2E blockThrottle tests", () => {
  scenario->Scenario.it(
    "Fetches once the head is blockThrottle blocks past, keeping the known head current meanwhile",
    ~sources=[{chain: 1337, methods}],
    async (~t, ~indexer, ~source) => {
      let sourceMock = source(1337)
      await fetchToHead(~indexer, ~source=sourceMock)

      sourceMock.setAutoHeight(304)
      await indexer.advanceTime(1000)
      t.expect((
        await indexer->chainMetric("envio_indexing_known_height"),
        sourceMock.pendingItemsQueries,
      )).toEqual((["304"], []))

      sourceMock.setAutoHeight(305)
      await indexer.advanceTime(1000)
      await sourceMock.expectItemsQueries([
        {fromBlock: 301, toBlock: Unbounded, reply: LeavePending},
      ])
    },
  )

  scenarioWithEndBlock->Scenario.it(
    "Fetches up to end_block once the head reaches it, short of the throttle",
    ~sources=[{chain: 1337, methods}],
    async (~t, ~indexer, ~source) => {
      let sourceMock = source(1337)
      await fetchToHead(~indexer, ~source=sourceMock, ~knownHeight=303)

      await sourceMock.expectItemsQueries([
        {fromBlock: 301, toBlock: Bounded(303), reply: LeavePending},
      ])
      t.expect(await indexer->chainMetric("envio_progress_ready")).toEqual(["0"])
    },
  )

  scenario->Scenario.it(
    "Waiting out the throttle is not counted as processing stalled on fetch",
    ~sources=[{chain: 1337, methods}],
    async (~t, ~indexer, ~source) => {
      let sourceMock = source(1337)
      await fetchToHead(~indexer, ~source=sourceMock)
      sourceMock.setAutoHeight(304)
      await indexer.advanceTime(1000)

      let stalledSeconds = () => indexer->chainMetric("envio_processing_stalled_on_fetch_seconds")
      let stalledAtWait = await stalledSeconds()
      // Real time: the stall counter reads the process clock, not the source clock.
      await Utils.delay(20)
      t.expect(await stalledSeconds()).toEqual(stalledAtWait)
    },
  )

  scenario->Scenario.it(
    "A chain the head has moved past by less than the throttle is synced and waits",
    ~sources=[{chain: 1337, methods}],
    async (~t, ~indexer, ~source) => {
      let sourceMock = source(1337)
      await fetchToHead(~indexer, ~source=sourceMock, ~knownHeight=302)
      await indexer.waitUntilReady()

      t.expect((
        await indexer->chainMetric("envio_progress_ready"),
        sourceMock.pendingItemsQueries,
      )).toEqual((["1"], []))
    },
  )

  scenarioWithOnBlock->Scenario.it(
    "A chain with a block handler waits for the throttle too",
    ~sources=[{chain: 1337, methods}],
    async (~t, ~indexer, ~source) => {
      let sourceMock = source(1337)
      await fetchToHead(~indexer, ~source=sourceMock)

      sourceMock.setAutoHeight(304)
      await indexer.advanceTime(1000)
      t.expect(sourceMock.pendingItemsQueries).toEqual([])

      sourceMock.setAutoHeight(305)
      await indexer.advanceTime(1000)
      await sourceMock.expectItemsQueries([{fromBlock: 301, reply: LeavePending}])
    },
  )

  scenario->Scenario.it(
    "A chain younger than blockThrottle starts fetching once it has that many blocks",
    ~sources=[{chain: 1337, methods}],
    async (~t, ~indexer, ~source) => {
      let sourceMock = source(1337)
      await Scenario.resolveInitialHeight(~source=sourceMock, ~head=4)
      await indexer.advanceTime(1000)
      let pendingAtFourBlocks = sourceMock.pendingItemsQueries->Array.length

      sourceMock.setAutoHeight(5)
      await indexer.advanceTime(1000)
      await sourceMock.expectItemsQueries([{fromBlock: 1, reply: LeavePending}])
      t.expect(pendingAtFourBlocks).toBe(0)
    },
  )

  scenario->Scenario.it(
    "A head still advancing towards blockThrottle does not report a stall",
    ~sources=[{chain: 1337, methods, pollingInterval: 5}],
    ~sourceTiming={
      newBlockStallTimeout: 200,
      newBlockStallTimeoutRealtime: 200,
    },
    async (~t, ~indexer, ~source) => {
      let sourceMock = source(1337)
      await fetchToHead(~indexer, ~source=sourceMock)

      // Four blocks spread over twice the stall window, each inside it.
      for height in 301 to 304 {
        sourceMock.setAutoHeight(height)
        await indexer.advanceTime(120)
      }

      t.expect(
        indexer.infoAndAboveLogs()->Array.filter(
          ({msg}) => msg->String.startsWith("No new blocks detected"),
        ),
      ).toEqual([])
    },
  )
})
