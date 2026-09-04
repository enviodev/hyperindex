open Vitest

// ClickHouse can be ahead of Postgres: a batch lands there and the process dies
// before Postgres commits the checkpoint covering it. The next start resumes
// from the Postgres checkpoint and has to drop everything ClickHouse holds past
// it — otherwise the orphaned rows stay, and the current-state view serves them
// as soon as a later checkpoint catches up to their id.
//
// Nothing surfaces a trim that quietly does nothing: the write path keeps
// working either way, so only reading the rows back after a restart tells the
// difference.

let scenario = Scenario.make(
  ~configYaml=`
name: clickhouse-trim
chains:
  - id: 1
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 0
    contracts:
      - name: Token
        address: "0x0000000000000000000000000000000000000001"
        events:
          - event: Transfer(address indexed from, address indexed to, uint256 value)
`,
  ~schema=`
type Counter {
  id: ID!
  count: BigInt!
}
`,
  ~unsupported=[
    {backend: #postgres, reason: "asserts against a ClickHouse server"},
  ],
)

type counter = {id: string, count: bigint}
type counterOps = {set: counter => unit}
type counterContext = {@as("Counter") counter: counterOps}

let setCounter = (~count) =>
  async (args: Internal.handlerArgs) => {
    let context = args.context->(Utils.magic: Internal.handlerContext => counterContext)
    context.counter.set({id: "total", count})
  }

// A checkpoint id no run reaches, so anything stamped with it can only be the
// rows this test planted.
let orphanCheckpointId = "999999999"

describe("ClickHouse sink resuming past its own rows", () => {
  scenario->Scenario.it(
    "drops history and checkpoints written past the resumed checkpoint",
    ~sources=[{chain: 1}],
    async (~t, ~indexer, ~source) => {
      let source = source(1)
      source.resolveGetHeightOrThrow(10)
      source.resolveGetItemsOrThrow(
        [{blockNumber: 5, logIndex: 0, handler: setCounter(~count=42n)}],
        ~latestFetchedBlockNumber=10,
      )
      await indexer.getBatchWritePromise()

      let database = TestClickHouse.currentDatabase()

      // Stands in for the batch that reached ClickHouse before the process died:
      // a history row and the checkpoint covering it, both past what Postgres
      // committed.
      let _ = await TestClickHouse.query(
        `INSERT INTO \`${database}\`.\`envio_history_Counter\` (\`id\`, \`count\`, \`envio_checkpoint_id\`, \`envio_change\`) VALUES ('total', '99', ${orphanCheckpointId}, 'SET')`,
      )
      let _ = await TestClickHouse.query(
        `INSERT INTO \`${database}\`.\`envio_checkpoints\` (\`id\`, \`chain_id\`, \`block_number\`, \`block_hash\`, \`events_processed\`) VALUES (${orphanCheckpointId}, 1, 999, NULL, 1)`,
      )

      let orphanCounts = async () => {
        let history = await TestClickHouse.query(
          `SELECT count() FROM \`${database}\`.\`envio_history_Counter\` WHERE \`envio_checkpoint_id\` = ${orphanCheckpointId} FORMAT TabSeparated`,
        )
        let checkpoints = await TestClickHouse.query(
          `SELECT count() FROM \`${database}\`.\`envio_checkpoints\` WHERE \`id\` = ${orphanCheckpointId} FORMAT TabSeparated`,
        )
        (history->String.trim, checkpoints->String.trim)
      }

      let planted = await orphanCounts()

      // Resumes from the Postgres checkpoint, which is behind both rows above.
      let _ = await indexer.restart()

      // No wait here on purpose: resume runs the trim with `mutations_sync`,
      // so by the time it returns the rows are gone rather than scheduled to be.
      let trimmed = await orphanCounts()

      let survivors = await TestClickHouse.query(
        `SELECT id, count FROM \`${database}\`.\`Counter\` FORMAT JSONEachRow`,
      )

      t.expect((planted, trimmed, survivors->String.trim)).toEqual((
        ("1", "1"),
        ("0", "0"),
        `{"id":"total","count":"42"}`,
      ))
    },
  )
})
