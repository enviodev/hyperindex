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

  // A row carries what identifies the event and the block it came from, and
  // every other block and transaction field as JSON — a bigint as its digits.
  scenario->Scenario.it(
    "keep the event's identity and its block's fields",
    ~sources=[{chain: 1}],
    async (~t, ~indexer, ~source) => {
      let source = source(1)
      source.resolveGetHeightOrThrow(300)
      source.resolveGetItemsOrThrow(
        [
          {
            blockNumber: 5,
            logIndex: 3,
            handler: async _ => (),
            blockFields: dict{
              "timestamp": 9999->(Utils.magic: int => unknown),
              "hash": "0xblockhash"->(Utils.magic: string => unknown),
              "gasUsed": 99n->(Utils.magic: bigint => unknown),
              "miner": "0xminer"->(Utils.magic: string => unknown),
            },
            transactionFields: dict{
              "hash": "0xtxhash"->(Utils.magic: string => unknown),
              "transactionIndex": 7->(Utils.magic: int => unknown),
              "value": 5n->(Utils.magic: bigint => unknown),
            },
          },
        ],
        ~latestFetchedBlockNumber=100,
      )
      await indexer.getBatchWritePromise()

      let {sql, pgSchema} = indexer.pg
      let rows: array<JSON.t> = await sql->Sql.query(
        `SELECT "chain_id", "event_id"::text AS "event_id", "event_name", "contract_name",
                "block_number", "log_index", "src_address", "block_hash", "block_timestamp",
                "block_fields", "transaction_fields", "params"
           FROM "${pgSchema}"."raw_events";`,
      )

      t.expect(rows).toEqual([
        JSON.parseOrThrow(
          `{
          "chain_id": 1,
          "event_id": "${EventUtils.packEventIndex(~logIndex=3, ~blockNumber=5)->BigInt.toString}",
          "event_name": "MockEvent",
          "contract_name": "Gravatar",
          "block_number": 5,
          "log_index": 3,
          "src_address": "0x0000000000000000000000000000000000000000",
          "block_hash": "0xblockhash",
          "block_timestamp": 9999,
          "block_fields": {"miner": "0xminer", "gasUsed": "99"},
          "transaction_fields": {"hash": "0xtxhash", "transactionIndex": 7, "value": "5"},
          "params": "null"
        }`,
        ),
      ])
    },
  )
})
