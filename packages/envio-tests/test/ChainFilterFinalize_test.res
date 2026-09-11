open Vitest

// `envio start --chain` runs one process per chain against a schema that
// `db-migrate up` created for all of them. The schema's indexes are global
// objects on shared tables, so no process builds them while another chain is
// still backfilling. Each process stamps its own chains and then reads the
// table: the last one to catch up is the one that sees it fully stamped.

let schema = `
type A {
  id: ID!
  b: B! @index
}

type B {
  id: ID!
}
`

let chainYaml = (chainId, address) => `
  - id: ${chainId->Int.toString}
    rpc:
      url: https://rpc${chainId->Int.toString}.example.test
      for: sync
    start_block: 1
    contracts:
      - name: Gravatar
        address: "${address}"
`

let scenario = Scenario.make(
  ~configYaml=`
name: chain-filter-finalize
disable_default_cross_chain: true
contracts:
  - name: Gravatar
    events:
      - event: "TestEvent()"
chains:${chainYaml(1, "0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3")}${chainYaml(
      137,
      "0x3B2f78c5BF6D9C12Ee1225D5F374aa91204580c3",
    )}`,
  ~schema,
)

let aBIdIndexName = IndexDefinition.single(~tableName="A", ~column="b_id")->IndexDefinition.name

let hasSchemaIndex = async (~sql, ~pgSchema) => {
  let rows =
    (await sql->Postgres.unsafe(IndexCatalog.makeQuery(~pgSchema)))->S.parseOrThrow(
      IndexCatalog.rowsSchema,
    )
  IndexCatalog.fromRows(~rows)
  ->IndexCatalog.entries
  ->Array.some((entry: IndexCatalog.entry) => entry.name === aBIdIndexName)
}

// `ready_at` still means what it always did: the schema's indexes are committed.
// It lands on every chain at once, when the last of them finishes backfilling.
let readyByChainId = async (~sql, ~pgSchema) => {
  let rows: array<{"id": ChainId.t, "ready_at": Null.t<Date.t>}> = await sql->Postgres.unsafe(
    `SELECT "id", "ready_at" FROM "${pgSchema}"."envio_chains" ORDER BY "id";`,
  )
  rows->Array.map(row => (
    row["id"]->ChainId.toString,
    row["ready_at"]->Null.toOption->Option.isSome,
  ))
}

// Not `waitUntilReady`: a process whose sibling is still backfilling never
// reports ready, which is the point of the test below.
let catchUp = async (~indexer: IndexerRunner.t, ~source: MockSource.t) => {
  source.resolveGetHeightOrThrow(100)
  source.resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=100)
  await indexer.waitUntilIdle()
}

describe("envio start --chain", () => {
  // Standing down must not be final. The chains are judged from what they have
  // committed, so a chain can read as behind for a moment - a burst it hasn't
  // processed yet, or a sibling that catches up a second later. If that pass
  // were the only one, the indexes would stay unbuilt for the rest of the run.
  scenario->Scenario.it(
    "Comes back to the indexes once the chain that was behind catches up",
    ~sources=[{chain: 1}, {chain: 137}],
    // Both of these are long in production, where the chain being waited on can
    // be behind for hours: a caught-up chain drops to reduced polling, and the
    // pass that reads the other chains is throttled. This test drives them a
    // tick at a time.
    ~finalizeRetryIntervalMillis=0.,
    ~reducedPollingInterval=0,
    async (~t, ~indexer, ~source) => {
      let running = await indexer.restart(~chains=[ChainId.fromInt(1)], ())
      let {sql, pgSchema} = running.pg
      let sourceOne = source(1)
      await catchUp(~indexer=running, ~source=sourceOne)

      t.expect(
        await hasSchemaIndex(~sql, ~pgSchema),
        ~message="Chain 137 is behind, so this pass leaves the indexes alone",
      ).toEqual(false)

      // Chain 137's own process reaching its head, which this one only ever
      // sees as the row that process committed.
      let _ = await sql->Postgres.unsafe(
        `UPDATE "${pgSchema}"."envio_chains" SET "progress_block" = 100, "source_block" = 100 WHERE "id" = 137;`,
      )

      // A caught-up chain that hasn't finalized polls its source on the reduced
      // interval, and every round it completes brings the loop back here.
      sourceOne.setAutoHeight(101)
      let attempts = ref(0)
      while !(await hasSchemaIndex(~sql, ~pgSchema)) && attempts.contents < 500 {
        attempts := attempts.contents + 1
        await Utils.delay(2)
      }

      t.expect(
        (await hasSchemaIndex(~sql, ~pgSchema), await readyByChainId(~sql, ~pgSchema)),
        ~message="The same process picks the debt back up, with no restart",
      ).toEqual((true, [("1", true), ("137", true)]))
    },
  )

  scenario->Scenario.it(
    "Builds the schema's indexes only once every chain has finished backfill",
    ~sources=[{chain: 1}, {chain: 137}],
    async (~t, ~indexer, ~source) => {
      let first = await indexer.restart(~chains=[ChainId.fromInt(1)], ())
      let {sql, pgSchema} = first.pg
      await catchUp(~indexer=first, ~source=source(1))

      t.expect(
        (
          await hasSchemaIndex(~sql, ~pgSchema),
          await readyByChainId(~sql, ~pgSchema),
          await first.metric("envio_schema_indexes_pending"),
          await first.metric("envio_progress_ready"),
        ),
        ~message="Chain 1 finished its backfill, but chain 137 is still behind, so nothing builds the indexes, chain 1 holds short of realtime rather than reporting itself ready, and the gauge says the indexes are outstanding",
      ).toEqual((
        false,
        [("1", false), ("137", false)],
        [{value: "1", labels: dict{}}],
        [{value: "0", labels: dict{"chainId": "1"}}],
      ))

      let second = await first.restart(~chains=[ChainId.fromInt(137)], ())
      await catchUp(~indexer=second, ~source=source(137))

      t.expect(
        (
          await hasSchemaIndex(~sql, ~pgSchema),
          await readyByChainId(~sql, ~pgSchema),
          await second.metric("envio_schema_indexes_pending"),
          await second.metric("envio_progress_ready"),
        ),
        ~message="The last chain to catch up finds every chain at its head, builds the indexes, readiness lands on every chain at once, and the gauge clears",
      ).toEqual((
        true,
        [("1", true), ("137", true)],
        [{value: "0", labels: dict{}}],
        [{value: "1", labels: dict{"chainId": "137"}}],
      ))
    },
  )
})
