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
    max_reorg_depth: 199
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
  ~unsupported=[
    {
      backend: #clickhouse,
      reason: "reads raw_events with Postgres SQL, which a run keeping no entity in Postgres skips",
    },
  ],
)

type row = {
  chain_id: int,
  contract_name: string,
  block_number: int,
  log_index: int,
}

let read = async (sql, ~pgSchema) => {
  let rows: array<row> = await sql->Sql.queryForTests(
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
      await source.expectItemsQueries([
        {
          fromBlock: 1,
          reply: Respond({
            items: [event(~block=50, ~logIndex=0), event(~block=50, ~logIndex=3)],
            latestFetchedBlockNumber: 100,
          }),
        },
      ])
      await indexer.getBatchWritePromise()
      await source.expectItemsQueries([
        {
          fromBlock: 101,
          reply: Respond({items: [event(~block=200, ~logIndex=1)], latestFetchedBlockNumber: 300}),
        },
      ])
      await indexer.getBatchWritePromise()
      await indexer.usePostgresSql(
        async sql => {
          let beforeReorg = await sql->read(~pgSchema=indexer.pgSchema)

          await Scenario.reorgAbove(
            ~indexer,
            ~source,
            ~head=300,
            ~validUpTo=100,
            ~refetched=[event(~block=200, ~logIndex=1)],
          )

          t.expect((beforeReorg, await sql->read(~pgSchema=indexer.pgSchema))).toEqual((
            [
              row(~block=50, ~logIndex=0),
              row(~block=50, ~logIndex=3),
              row(~block=200, ~logIndex=1),
            ],
            [
              row(~block=50, ~logIndex=0),
              row(~block=50, ~logIndex=3),
              row(~block=200, ~logIndex=1),
              row(~block=200, ~logIndex=1),
            ],
          ))
        },
      )
    },
  )

  // `event_id` keeps 16 bits for the log index, so a log above 65535 can't have
  // a row of its own: some providers number synthetic logs as high as
  // 0xffffffe2. Its handler still runs; the row is skipped with a warning.
  scenario->Scenario.it(
    "skip a log whose index event_id can't hold, with a warning",
    ~sources=[{chain: 1}],
    async (~t, ~indexer, ~source) => {
      let handledLogIndexes = []
      let counted = (~block, ~logIndex): MockSource.itemMock => {
        blockNumber: block,
        logIndex,
        handler: async ({event}) =>
          handledLogIndexes
          ->Array.push(
            (
              event->(
                Utils.magic: Internal.event => Internal.genericEvent<unknown, unknown, unknown>
              )
            ).logIndex,
          )
          ->ignore,
      }
      let source = source(1)
      source.resolveGetHeightOrThrow(300)
      await source.expectItemsQueries([
        {
          fromBlock: 1,
          reply: Respond({
            items: [
              counted(~block=4, ~logIndex=65535),
              counted(~block=4, ~logIndex=65536),
              counted(~block=5, ~logIndex=0),
              counted(~block=5, ~logIndex=4294967266.->(Utils.magic: float => int)),
            ],
            latestFetchedBlockNumber: 100,
          }),
        },
      ])
      await indexer.getBatchWritePromise()

      await indexer.usePostgresSql(
        async sql =>
          t.expect((
            await sql->read(~pgSchema=indexer.pgSchema),
            indexer.allLogsAsJson()->Array.filter(
              line =>
                switch line->Dict.get("msg") {
                | Some(String(msg)) => msg->String.startsWith("Not storing a raw event")
                | _ => false
                },
            ),
            handledLogIndexes,
          )).toEqual((
            [row(~block=4, ~logIndex=65535), row(~block=5, ~logIndex=0)],
            [(4, 65536.), (5, 4294967266.)]->Array.map(
              ((block, logIndex)) =>
                dict{
                  "level": JSON.String("warn"),
                  "msg": JSON.String(
                    "Not storing a raw event for a log whose index is above 65535, the most raw_events' event_id holds",
                  ),
                  "chainId": JSON.Number(1.),
                  "contract": JSON.String("Gravatar"),
                  "event": JSON.String("MockEvent"),
                  "block": JSON.Number(block->Int.toFloat),
                  "logIndex": JSON.Number(logIndex),
                  "address": JSON.String("0x0000000000000000000000000000000000000000"),
                },
            ),
            [65535, 65536, 0, 4294967266.->(Utils.magic: float => int)],
          )),
      )
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
      await source.expectItemsQueries([
        {
          fromBlock: 1,
          reply: Respond({
            items: [
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
            latestFetchedBlockNumber: 100,
          }),
        },
      ])
      await indexer.getBatchWritePromise()

      await indexer.usePostgresSql(
        async sql => {
          let pgSchema = indexer.pgSchema
          let rows: array<JSON.t> = await sql->Sql.queryForTests(
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
    },
  )
})
