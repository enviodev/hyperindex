open Vitest

let sql = PgStorage.makeClient()

let indexNames = async () => {
  let rows =
    (
      await sql->Postgres.unsafe(
        IndexRegistry.makeCatalogQuery(~pgSchema=Env.Db.publicSchema),
      )
    )->S.parseOrThrow(IndexRegistry.catalogRowsSchema)
  rows
  ->Array.map((row: IndexRegistry.catalogRow) => row.indexName)
  ->Array.toSorted(String.compare)
}

let readyAtByChainId = async () => {
  let rows: array<{"id": int, "ready_at": Null.t<Date.t>}> =
    await sql->Postgres.unsafe(
      `SELECT "id", "ready_at" FROM "${Env.Db.publicSchema}"."envio_chains" ORDER BY "id";`,
    )
  rows->Array.map(row => (row["id"], row["ready_at"]->Null.toOption->Option.isSome))
}

describe("Deferred schema indexes", () => {
  Async.it(
    "Are absent through backfill, committed with ready_at, and kept across a restart",
    async t => {
      let sourceMock = MockIndexer.Source.make(~chain=#1337, [#getHeightOrThrow, #getItemsOrThrow])
      let indexerMock = await MockIndexer.Indexer.make(
        ~chains=[{chain: #1337, sourceConfig: Config.CustomSources([sourceMock.source])}],
        ~shouldRollbackOnReorg=false,
      )
      await Utils.delay(0)

      t.expect(
        (
          (await indexNames())->Array.includes("A_b_id"),
          await readyAtByChainId(),
          await indexerMock.metric("envio_progress_ready"),
        ),
        ~message="Backfill runs without the schema's read indexes, and nothing is ready",
      ).toEqual((false, [(1337, false)], [{value: "0", labels: dict{"chainId": "1337"}}]))

      sourceMock.resolveGetHeightOrThrow(100)
      await Utils.delay(0)
      await Utils.delay(0)
      sourceMock.resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=100)
      await indexerMock.getBatchWritePromise()

      t.expect(
        (
          (await indexNames())->Array.includes("A_b_id"),
          await readyAtByChainId(),
          await indexerMock.metric("envio_progress_ready"),
        ),
        ~message="ready_at is only committed once every schema-defined index exists",
      ).toEqual((true, [(1337, true)], [{value: "1", labels: dict{"chainId": "1337"}}]))

      let indexesBeforeRestart = await indexNames()
      let _restarted = await indexerMock.restart()
      await Utils.delay(0)

      t.expect(
        (await indexNames(), await readyAtByChainId()),
        ~message="A resume rediscovers the indexes from the catalog — none are dropped or recreated",
      ).toEqual((indexesBeforeRestart, [(1337, true)]))
    },
  )
})
