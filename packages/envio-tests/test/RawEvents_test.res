open Vitest

// With `raw_events: true` every processed event is kept as a row. A rollback
// leaves those rows alone, so the same event processed again after a reorg
// lands a second time rather than being refused as a duplicate.

let scenario = Scenario.make(
  ~configYaml=`
name: raw-events
raw_events: true
rollback_on_reorg: true
chains:
  - id: 1
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 1
    max_reorg_depth: 200
    contracts:
      - name: Gravatar
        address: "0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3"
        events:
          - event: "TestEvent()"
`,
  ~schema=`
type Gravatar {
  id: ID!
}
`,
)

type row = {
  chain_id: int,
  contract_name: string,
  block_number: int,
  log_index: int,
}

let read = async (indexer: IndexerRunner.t) => {
  let {sql, pgSchema} = indexer.pg
  let rows: array<row> = await sql->Sql.query(
    `SELECT "chain_id", "contract_name", "block_number", "log_index"
       FROM "${pgSchema}"."raw_events" ORDER BY "serial";`,
  )
  rows
}

let event = (~block, ~logIndex): MockSource.itemMock => {
  blockNumber: block,
  logIndex,
  handler: async _ => (),
}

let row = (~block, ~logIndex) => {
  chain_id: 1,
  contract_name: "Gravatar",
  block_number: block,
  log_index: logIndex,
}

describe("Raw events", () => {
  scenario->Scenario.it(
    "are stored per processed event, and again when a reorg re-processes one",
    ~sources=[{chain: 1, methods: [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes]}],
    async (~t, ~indexer, ~source) => {
      let source = source(1)
      source.resolveGetHeightOrThrow(300)
      await Utils.delay(0)
      await Utils.delay(0)
      await MockSource.waitItemsQuery(source)
      source.resolveGetItemsOrThrow(
        [event(~block=50, ~logIndex=0), event(~block=50, ~logIndex=3)],
        ~latestFetchedBlockNumber=100,
      )
      await indexer.getBatchWritePromise()
      await MockSource.waitItemsQuery(source)
      source.resolveGetItemsOrThrow([event(~block=200, ~logIndex=1)], ~latestFetchedBlockNumber=300)
      await indexer.getBatchWritePromise()
      let beforeReorg = await read(indexer)

      await Scenario.reorgAbove(
        ~indexer,
        ~source,
        ~head=300,
        ~validUpTo=100,
        ~refetched=[event(~block=200, ~logIndex=1)],
      )

      t.expect((beforeReorg, await read(indexer))).toEqual((
        [row(~block=50, ~logIndex=0), row(~block=50, ~logIndex=3), row(~block=200, ~logIndex=1)],
        [
          row(~block=50, ~logIndex=0),
          row(~block=50, ~logIndex=3),
          row(~block=200, ~logIndex=1),
          row(~block=200, ~logIndex=1),
        ],
      ))
    },
  )
})
