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

let indexNames = async (~sql, ~pgSchema) => {
  let rows =
    (await sql->Postgres.unsafe(IndexCatalog.makeQuery(~pgSchema)))->S.parseOrThrow(
      IndexCatalog.rowsSchema,
    )
  IndexCatalog.fromRows(~rows)
  ->IndexCatalog.entries
  ->Array.filter((entry: IndexCatalog.entry) => entry.name === aBIdIndexName)
  ->Array.map((entry: IndexCatalog.entry) => entry.name)
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

let catchUp = async (~indexer: IndexerRunner.t, ~source: MockSource.t) => {
  source.resolveGetHeightOrThrow(100)
  source.resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=100)
  await indexer.waitUntilReady()
  await indexer.waitUntilIdle()
}

describe("envio start --chain", () => {
  // Standing down must not be final. The chains are judged from what they have
  // committed, so a chain can read as behind for a moment — a burst it hasn't
  // processed yet, or a sibling that catches up a second later. If that pass
  // were the only one, the indexes would stay unbuilt for the rest of the run.
  scenario->Scenario.it(
    "Comes back to the indexes once the chain that was behind catches up",
    ~sources=[{chain: 1}, {chain: 137}],
    async (~t, ~indexer, ~source) => {
      let running = await indexer.restart(~chains=[ChainId.fromInt(1)], ())
      let {sql, pgSchema} = running.pg
      let sourceOne = source(1)
      await catchUp(~indexer=running, ~source=sourceOne)

      t.expect(
        await indexNames(~sql, ~pgSchema),
        ~message="Chain 137 is behind, so this pass leaves the indexes alone",
      ).toEqual([])

      // Chain 137's own process reaching its head, which this one only ever
      // sees as the row that process committed.
      let _ = await sql->Postgres.unsafe(
        `UPDATE "${pgSchema}"."envio_chains" SET "progress_block" = 100, "source_block" = 100 WHERE "id" = 137;`,
      )

      // Any batch brings the loop back round.
      sourceOne.resolveGetHeightOrThrow(101)
      sourceOne.resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=101)
      await running.waitUntilIdle()

      t.expect(
        (await indexNames(~sql, ~pgSchema), await readyByChainId(~sql, ~pgSchema)),
        ~message="The same process picks the debt back up, with no restart",
      ).toEqual(([aBIdIndexName], [("1", true), ("137", true)]))
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
        (await indexNames(~sql, ~pgSchema), await readyByChainId(~sql, ~pgSchema)),
        ~message="Chain 1 finished its backfill, but chain 137 is still behind, so nothing builds the indexes and no chain is ready",
      ).toEqual(([], [("1", false), ("137", false)]))

      let second = await first.restart(~chains=[ChainId.fromInt(137)], ())
      await catchUp(~indexer=second, ~source=source(137))

      t.expect(
        (await indexNames(~sql, ~pgSchema), await readyByChainId(~sql, ~pgSchema)),
        ~message="The last chain to catch up finds every chain at its head, builds the indexes, and readiness lands on every chain at once",
      ).toEqual(([aBIdIndexName], [("1", true), ("137", true)]))
    },
  )
})
