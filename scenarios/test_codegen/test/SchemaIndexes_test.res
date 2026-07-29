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
      let sourceMock = MockIndexer.Source.make(~chainId=#1337, [#getHeightOrThrow, #getItemsOrThrow])
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

describe("Automatic getWhere indexes", () => {
  // `optionalStringToTestLinkedEntities` carries no @index, so nothing creates
  // an index for it up front. Querying it has to build one mid-backfill and
  // still return the right rows.
  Async.it("Are built mid-backfill by the first query that needs one", async t => {
    let matched = ref([])

    let sourceMock = MockIndexer.Source.make(~chainId=#1337, [#getHeightOrThrow, #getItemsOrThrow])
    let indexerMock = await MockIndexer.Indexer.make(
      ~chains=[{chain: #1337, sourceConfig: Config.CustomSources([sourceMock.source])}],
      ~shouldRollbackOnReorg=false,
    )
    await Utils.delay(0)
    sourceMock.resolveGetHeightOrThrow(1000)
    await Utils.delay(0)
    await Utils.delay(0)

    sourceMock.resolveGetItemsOrThrow(
      [
        {
          blockNumber: 10,
          logIndex: 0,
          handler: async ({context}) => {
            context.\"A".set({
              id: "1",
              b_id: "b",
              optionalStringToTestLinkedEntities: Some("wanted"),
            })
            context.\"A".set({
              id: "2",
              b_id: "b",
              optionalStringToTestLinkedEntities: Some("other"),
            })
            context.\"A".set({
              id: "3",
              b_id: "b",
              optionalStringToTestLinkedEntities: Some("wanted"),
            })
          },
        },
      ],
      ~latestFetchedBlockNumber=10,
    )
    await indexerMock.getBatchWritePromise()

    t.expect(
      (await indexNames())->Array.includes("A_optionalStringToTestLinkedEntities"),
      ~message="Nothing has queried the field yet, so no index exists for it",
    ).toBe(false)

    sourceMock.resolveGetItemsOrThrow(
      [
        {
          blockNumber: 20,
          logIndex: 0,
          handler: async ({context}) => {
            let rows = await context.\"A".getWhere({
              optionalStringToTestLinkedEntities: {_eq: Some("wanted")},
            })
            matched :=
              rows
              ->Array.map((entity: Indexer.Entities.A.t) => entity.id)
              ->Array.toSorted(String.compare)
          },
        },
      ],
      ~latestFetchedBlockNumber=20,
    )
    await indexerMock.getBatchWritePromise()

    t.expect(
      (
        matched.contents,
        (await indexNames())->Array.includes("A_optionalStringToTestLinkedEntities"),
        (await indexNames())->Array.includes("A_b_id"),
        await readyAtByChainId(),
      ),
      ~message="The query builds its own index during backfill and still returns the right rows, while the schema's own indexes stay deferred",
    ).toEqual((["1", "3"], true, false, [(1337, false)]))

    // The automatic index is the indexer's own, so finalizing must leave it be.
    sourceMock.resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=1000)
    await indexerMock.getBatchWritePromise()

    t.expect(
      (
        (await indexNames())->Array.includes("A_optionalStringToTestLinkedEntities"),
        (await indexNames())->Array.includes("A_b_id"),
        await readyAtByChainId(),
      ),
      ~message="Reaching ready adds the schema indexes without disturbing the automatic one",
    ).toEqual((true, true, [(1337, true)]))
  })
})
