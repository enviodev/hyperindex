open Vitest

// `start_block: latest` must resolve once, against the chain's head at first
// deploy, and then never again - `indexer.restart()` (a normal resume, not
// the CLI's `-r`/`--restart` reset flag) reuses the persisted value even if
// the chain's head has moved on, so any downtime gets backfilled rather than
// skipped.
//
// The resolution call happens inside `Persistence.init`, which `IndexerRunner`
// fully awaits before a test body ever runs - so, unlike every other height
// call in this suite, it can't be answered via `source.setAutoHeight` from
// inside the test. It's pre-configured via `~autoHeight` on the mock instead
// (see MockSource.make / Scenario.sourceMock).

let schema = `
type A {
  id: ID!
}
`

let contractsYaml = `
contracts:
  - name: Gravatar
    events:
      - event: "TestEvent()"
`

let gravatar = "0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3"

let chainYaml = (~chainId, ~startBlock) =>
  `
  - id: ${chainId->Int.toString}
    rpc:
      url: https://rpc${chainId->Int.toString}.example.test
      for: sync
    start_block: ${startBlock}
    contracts:
      - name: Gravatar
        address: "${gravatar}"
`

let scenario = Scenario.make(
  ~configYaml=`
name: start-block-latest${contractsYaml}chains:${chainYaml(~chainId=1337, ~startBlock="latest")}`,
  ~schema,
)

let mixedScenario = Scenario.make(
  ~configYaml=`
name: start-block-latest-mixed${contractsYaml}chains:${chainYaml(
      ~chainId=1,
      ~startBlock="5",
    )}${chainYaml(~chainId=1337, ~startBlock="latest")}`,
  ~schema,
)

let methods: array<MockSource.method> = [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes]

let persistedStartBlocks = async (~sql, ~pgSchema) => {
  let rows: array<{
    "id": int,
    "start_block": int,
  }> = await sql->Postgres.unsafe(
    `SELECT "id", "start_block" FROM "${pgSchema}"."envio_chains" ORDER BY "id";`,
  )
  rows->Array.map(row => (row["id"], row["start_block"]))
}

describe("start_block: latest", () => {
  scenario->Scenario.it(
    "resolves latest to the chain's head on first deploy, and never re-resolves on restart",
    ~sources=[{chain: 1337, methods, autoHeight: 1000}],
    async (~t, ~indexer, ~source) => {
      let source = source(1337)
      let {sql, pgSchema} = indexer.pg

      source.resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=1000)
      await indexer.getBatchWritePromise()

      t.expect(
        await persistedStartBlocks(~sql, ~pgSchema),
        ~message="latest resolves to the head observed at first deploy",
      ).toEqual([(1337, 1000)])

      t.expect(
        source.getHeightOrThrowCalls->Array.length >= 2,
        ~message="both the resolver's probe and the chain's own startup call hit the source",
      ).toEqual(true)

      // The head moves on while the indexer is "down" - restart must not
      // re-resolve "latest" against it.
      source.setAutoHeight(5000)
      let restarted = await indexer.restart()
      await restarted.waitUntilReady()

      t.expect(
        await persistedStartBlocks(~sql, ~pgSchema),
        ~message="start_block is reused from the first deploy, not re-resolved to the new head",
      ).toEqual([(1337, 1000)])
    },
  )

  mixedScenario->Scenario.it(
    "only resolves latest for the chain configured with it",
    ~sources=[{chain: 1, methods, autoHeight: 10}, {chain: 1337, methods, autoHeight: 2000}],
    async (~t, ~indexer, ~source) => {
      let source1 = source(1)
      let source1337 = source(1337)
      let {sql, pgSchema} = indexer.pg

      source1.resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=10)
      source1337.resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=2000)
      await indexer.getBatchWritePromise()

      t.expect(
        await persistedStartBlocks(~sql, ~pgSchema),
        ~message="chain 1 keeps its configured start block; only chain 1337 resolves latest",
      ).toEqual([(1, 5), (1337, 2000)])
    },
  )
})
