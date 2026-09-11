open Vitest

// `envio start --chain` runs one process per chain against a schema that
// `db-migrate up` created for all of them. A per-chain entity's rows live in one
// partition per chain, so each process builds its own chains' partition indexes
// and stamps its own chains ready. Nothing waits on a chain another process
// drives.

let schema = `
type A {
  id: ID!
  b: B! @index
}

type B {
  id: ID!
}
`

let chainYaml = (chainId, address) =>
  `
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

// The tables carrying an index on `A.b`, which is one partition per chain. The
// table name is what distinguishes them, so the assertion reads as the set of
// chains whose rows are indexed.
let indexedTables = async (~sql, ~pgSchema) => {
  let rows =
    (await sql->Postgres.unsafe(IndexCatalog.makeQuery(~pgSchema)))->S.parseOrThrow(
      IndexCatalog.rowsSchema,
    )
  rows
  ->Array.filter((row: IndexCatalog.row) => row.columns == ["b_id"])
  ->Array.map((row: IndexCatalog.row) => row.tableName)
  ->Array.toSorted(String.compare)
}

let readyByChainId = async (~sql, ~pgSchema) => {
  let rows: array<{
    "id": ChainId.t,
    "ready_at": Null.t<Date.t>,
  }> = await sql->Postgres.unsafe(
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
}

describe("envio start --chain", () => {
  scenario->Scenario.it(
    "Indexes and stamps each chain as it catches up, with the other chain never started",
    ~sources=[{chain: 1}, {chain: 137}],
    async (~t, ~indexer, ~source) => {
      let first = await indexer.restart(~chains=[ChainId.fromInt(1)], ())
      let {sql, pgSchema} = first.pg
      await catchUp(~indexer=first, ~source=source(1))

      t.expect(
        (
          await indexedTables(~sql, ~pgSchema),
          await readyByChainId(~sql, ~pgSchema),
          await first.metric("envio_progress_ready"),
        ),
        ~message="Chain 1 indexes its own partition and reports itself ready. Chain 137 has never been started, and holds nothing back",
      ).toEqual((
        ["A$1"],
        [("1", true), ("137", false)],
        [{value: "1", labels: dict{"chainId": "1"}}],
      ))

      let second = await first.restart(~chains=[ChainId.fromInt(137)], ())
      await catchUp(~indexer=second, ~source=source(137))

      t.expect(
        (await indexedTables(~sql, ~pgSchema), await readyByChainId(~sql, ~pgSchema)),
        ~message="Chain 137's process adds its own partition's index and stamps only its own row",
      ).toEqual((["A$1", "A$137"], [("1", true), ("137", true)]))
    },
  )
})
