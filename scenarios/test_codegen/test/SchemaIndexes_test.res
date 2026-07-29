open Vitest

let sql = PgStorage.makeClient()

let loadCatalog = async () => {
  let rows =
    (
      await sql->Postgres.unsafe(IndexCatalog.makeQuery(~pgSchema=Env.Db.publicSchema))
    )->S.parseOrThrow(IndexCatalog.rowsSchema)
  IndexCatalog.fromRows(~rows)
}

// Every index on `tableName` whose key columns start with `columns`, so an
// assertion can say what the schema holds rather than what SQL was emitted.
let findIndexes = async (~tableName, ~columns) => {
  let catalog = await loadCatalog()
  catalog
  ->IndexCatalog.entries
  ->Array.filter(entry =>
    entry.tableName === tableName &&
      columns->Array.everyWithIndex((column, idx) =>
        switch entry.columns->Array.get(idx) {
        | Some(actual) => actual.name === column
        | None => false
        }
      )
  )
  ->Array.toSorted((a, b) => String.compare(a.name, b.name))
}

let indexNames = async () => {
  let catalog = await loadCatalog()
  catalog
  ->IndexCatalog.entries
  ->Array.map((entry: IndexCatalog.entry) => entry.name)
  ->Array.toSorted(String.compare)
}

let isValid = (entry: IndexCatalog.entry) => entry.isValid
let isPartial = (entry: IndexCatalog.entry) => entry.isPartial
let predicate = (entry: IndexCatalog.entry) => entry.predicate
let method = (entry: IndexCatalog.entry) => entry.method

let aBIdIndex = IndexDefinition.single(~tableName="A", ~column="b_id")
let aBIdIndexName = aBIdIndex->IndexDefinition.name

let readyAtRows = async () => {
  let rows: array<{"id": ChainId.t, "ready_at": Null.t<Date.t>}> =
    await sql->Postgres.unsafe(
      `SELECT "id", "ready_at" FROM "${Env.Db.publicSchema}"."envio_chains" ORDER BY "id";`,
    )
  rows
}

let readyAtByChainId = async () =>
  (await readyAtRows())->Array.map(row => (row["id"], row["ready_at"]->Null.toOption->Option.isSome))

// Timestamps rather than flags, for the chains that have to share one.
let readyAtTimesByChainId = async () =>
  (await readyAtRows())->Array.map(row => (
    row["id"],
    row["ready_at"]->Null.toOption->Option.map(Date.toISOString),
  ))

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
          await findIndexes(~tableName="A", ~columns=["b_id"]),
          await readyAtByChainId(),
          await indexerMock.metric("envio_progress_ready"),
        ),
        ~message="Backfill runs without the schema's read indexes, and nothing is ready",
      ).toEqual(([], [(ChainId.fromInt(1337), false)], [{value: "0", labels: dict{"chainId": "1337"}}]))

      sourceMock.resolveGetHeightOrThrow(100)
      await Utils.delay(0)
      await Utils.delay(0)
      sourceMock.resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=100)
      await indexerMock.waitUntilReady()

      t.expect(
        (
          (await findIndexes(~tableName="A", ~columns=["b_id"]))->Array.map(entry => (
            entry.name,
            entry->isValid,
            entry->isPartial,
            entry->method,
          )),
          await readyAtByChainId(),
          await indexerMock.metric("envio_progress_ready"),
        ),
        ~message="ready_at is only committed once every schema-defined index exists",
      ).toEqual((
        [(aBIdIndexName, true, false, "btree")],
        [(ChainId.fromInt(1337), true)],
        [{value: "1", labels: dict{"chainId": "1337"}}],
      ))

      let indexesBeforeRestart = await indexNames()
      let restarted = await indexerMock.restart()
      await restarted.waitUntilIdle()

      t.expect(
        (await indexNames(), await readyAtByChainId()),
        ~message="A resume rediscovers the indexes from the catalog — none are dropped or recreated",
      ).toEqual((indexesBeforeRestart, [(ChainId.fromInt(1337), true)]))

      await restarted.stop()
    },
  )

  Async.it("Hold the indexer short of ready until they are committed", async t => {
    let gate = MockIndexer.Gate.make()
    let sourceMock = MockIndexer.Source.make(~chainId=#1337, [#getHeightOrThrow, #getItemsOrThrow])
    let indexerMock = await MockIndexer.Indexer.make(
      ~chains=[{chain: #1337, sourceConfig: Config.CustomSources([sourceMock.source])}],
      ~shouldRollbackOnReorg=false,
      ~mapStorage=storage => {
        ...storage,
        finalizeBackfill: (~entities, ~chainIds, ~readyAt) =>
          gate.wait()->Promise.then(() =>
            storage.finalizeBackfill(~entities, ~chainIds, ~readyAt)
          ),
      },
    )
    await Utils.delay(0)

    sourceMock.resolveGetHeightOrThrow(100)
    await Utils.delay(0)
    await Utils.delay(0)
    sourceMock.resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=100)
    while gate.entered.contents === 0 {
      await Utils.delay(0)
    }

    t.expect(
      (
        await findIndexes(~tableName="A", ~columns=["b_id"]),
        await readyAtByChainId(),
        await indexerMock.metric("envio_progress_ready"),
      ),
      ~message="Caught up to the head, but the indexes aren't committed so nothing is ready",
    ).toEqual(([], [(ChainId.fromInt(1337), false)], [{value: "0", labels: dict{"chainId": "1337"}}]))

    gate.release()
    await indexerMock.waitUntilReady()

    t.expect(
      (
        (await findIndexes(~tableName="A", ~columns=["b_id"]))->Array.map(entry => entry.name),
        await readyAtByChainId(),
      ),
    ).toEqual(([aBIdIndexName], [(ChainId.fromInt(1337), true)]))

    await indexerMock.stop()
  })

  // Every scheduling path that reaches the FinalizingIndexes phase joins the
  // in-flight run. Without that, a fetch response landing while the indexes are
  // being built starts a second pass over the same schema.
  Async.it("Finalize once however many ticks reach the phase", async t => {
    let gate = MockIndexer.Gate.make()
    let finalizeCalls = ref(0)
    let sourceMock = MockIndexer.Source.make(~chainId=#1337, [#getHeightOrThrow, #getItemsOrThrow])
    let indexerMock = await MockIndexer.Indexer.make(
      ~chains=[{chain: #1337, sourceConfig: Config.CustomSources([sourceMock.source])}],
      ~shouldRollbackOnReorg=false,
      ~mapStorage=storage => {
        ...storage,
        finalizeBackfill: (~entities, ~chainIds, ~readyAt) => {
          finalizeCalls := finalizeCalls.contents + 1
          gate.wait()->Promise.then(() =>
            storage.finalizeBackfill(~entities, ~chainIds, ~readyAt)
          )
        },
      },
    )
    await Utils.delay(0)

    sourceMock.resolveGetHeightOrThrow(100)
    await Utils.delay(0)
    await Utils.delay(0)
    sourceMock.resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=100)
    while gate.entered.contents === 0 {
      await Utils.delay(0)
    }

    t.expect(
      (finalizeCalls.contents, await indexerMock.metric("envio_progress_ready")),
      ~message="Finalization is under way and nothing is ready while it is held",
    ).toEqual((1, [{value: "0", labels: dict{"chainId": "1337"}}]))

    // A height update while the build is held: the chain fetches the new range
    // and its response schedules processing again.
    sourceMock.resolveGetHeightOrThrow(200)
    await MockIndexer.Helper.waitItemsQuery(sourceMock)
    sourceMock.resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=200)
    let ticks = ref(0)
    while ticks.contents < 20 {
      ticks := ticks.contents + 1
      await Utils.delay(0)
    }

    t.expect(
      (finalizeCalls.contents, await indexerMock.metric("envio_progress_ready")),
      ~message="The new tick joins the in-flight finalization instead of starting another",
    ).toEqual((1, [{value: "0", labels: dict{"chainId": "1337"}}]))

    gate.release()
    await indexerMock.waitUntilReady()

    t.expect(
      (finalizeCalls.contents, await indexerMock.metric("envio_progress_ready")),
      ~message="Releasing the build is what makes the indexer ready",
    ).toEqual((1, [{value: "1", labels: dict{"chainId": "1337"}}]))

    await indexerMock.stop()
  })

  // Readiness is a whole-indexer transition: one chain reaching its head means
  // nothing while another is still backfilling.
  Async.it("Wait for every chain before finalizing, and stamp them together", async t => {
    let finalizeCalls = ref(0)
    let chainA = MockIndexer.Source.make(~chainId=#100, [#getHeightOrThrow, #getItemsOrThrow])
    let chainB = MockIndexer.Source.make(~chainId=#1337, [#getHeightOrThrow, #getItemsOrThrow])
    let indexerMock = await MockIndexer.Indexer.make(
      ~chains=[
        {chain: #100, sourceConfig: Config.CustomSources([chainA.source])},
        {chain: #1337, sourceConfig: Config.CustomSources([chainB.source])},
      ],
      ~shouldRollbackOnReorg=false,
      ~mapStorage=storage => {
        ...storage,
        finalizeBackfill: (~entities, ~chainIds, ~readyAt) => {
          finalizeCalls := finalizeCalls.contents + 1
          storage.finalizeBackfill(~entities, ~chainIds, ~readyAt)
        },
      },
    )
    await Utils.delay(0)

    chainA.resolveGetHeightOrThrow(100)
    chainB.resolveGetHeightOrThrow(100)
    await Utils.delay(0)
    await Utils.delay(0)

    await MockIndexer.Helper.waitItemsQuery(chainA)
    chainA.resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=100)
    await indexerMock.getBatchWritePromise()

    t.expect(
      (finalizeCalls.contents, await readyAtByChainId()),
      ~message="Chain A is at its head, but chain B is still backfilling",
    ).toEqual((0, [(ChainId.fromInt(100), false), (ChainId.fromInt(1337), false)]))

    await MockIndexer.Helper.waitItemsQuery(chainB)
    chainB.resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=100)
    await indexerMock.waitUntilReady()

    let readyAtTimes = await readyAtTimesByChainId()
    let times = readyAtTimes->Array.map(((_, readyAt)) => readyAt)
    t.expect(
      (
        finalizeCalls.contents,
        readyAtTimes->Array.map(((id, _)) => id),
        times->Array.every(Option.isSome),
        times->Array.get(0) == times->Array.get(1),
        await indexerMock.metric("envio_progress_ready"),
      ),
      ~message="Both chains are stamped with the same timestamp by a single finalization",
    ).toEqual((
      1,
      [ChainId.fromInt(100), ChainId.fromInt(1337)],
      true,
      true,
      [
        {value: "1", labels: dict{"chainId": "100"}},
        {value: "1", labels: dict{"chainId": "1337"}},
      ],
    ))

    await indexerMock.stop()
  })

  // The false-ready bug: `A_b_id` was the name the indexer picked for
  // `A(b_id)`, so an unrelated index holding it on another table turned
  // `CREATE INDEX IF NOT EXISTS` into a no-op and the indexer reported ready
  // with `A(b_id)` unindexed.
  Async.it("Reach ready even when another table holds the legacy index name", async t => {
    let sourceMock = MockIndexer.Source.make(~chainId=#1337, [#getHeightOrThrow, #getItemsOrThrow])
    let indexerMock = await MockIndexer.Indexer.make(
      ~chains=[{chain: #1337, sourceConfig: Config.CustomSources([sourceMock.source])}],
      ~shouldRollbackOnReorg=false,
    )
    // The height is unresolved, so the tables exist but the backfill is stalled
    // and no schema index has been created yet.
    await Utils.delay(0)

    let _ = await sql->Postgres.unsafe(
      `CREATE INDEX "A_b_id" ON "${Env.Db.publicSchema}"."B"("c_id");`,
    )

    sourceMock.resolveGetHeightOrThrow(100)
    await Utils.delay(0)
    await Utils.delay(0)
    sourceMock.resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=100)
    await indexerMock.waitUntilReady()

    let conflicting = await findIndexes(~tableName="B", ~columns=["c_id"])
    let aIndexes = await findIndexes(~tableName="A", ~columns=["b_id"])

    t.expect(
      (
        await indexerMock.metric("envio_progress_ready"),
        conflicting->Array.map(entry => entry.name),
        aIndexes->Array.map(entry => (entry->isValid, entry->isPartial, entry->predicate)),
      ),
      ~message="The conflicting index is left alone and A(b_id) still gets a usable index of its own",
    ).toEqual((
      [{value: "1", labels: dict{"chainId": "1337"}}],
      ["A_b_id"],
      [(true, false, None)],
    ))

    t.expect(
      aIndexes->Array.map(entry => entry.name),
      ~message="The generated name can't be the one an unrelated index took",
    ).toEqual([aBIdIndexName])

    await indexerMock.stop()
  })
})

describe("Automatic getWhere indexes", () => {
  // `optionalStringToTestLinkedEntities` carries no @index, so nothing creates
  // an index for it up front. Querying it has to build one mid-backfill and
  // still return the right rows.
  Async.it("Are built mid-backfill by the first query that needs one", async t => {
    let matched = ref([])
    let optionalColumn = "optionalStringToTestLinkedEntities"

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
      await findIndexes(~tableName="A", ~columns=[optionalColumn]),
      ~message="Nothing has queried the field yet, so no index exists for it",
    ).toEqual([])

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
        (await findIndexes(~tableName="A", ~columns=[optionalColumn]))->Array.map(entry => (
          entry.name,
          entry->isValid,
        )),
        await findIndexes(~tableName="A", ~columns=["b_id"]),
        await readyAtByChainId(),
      ),
      ~message="The query builds its own index during backfill and still returns the right rows, while the schema's own indexes stay deferred",
    ).toEqual((
      ["1", "3"],
      [
        (
          IndexDefinition.single(~tableName="A", ~column=optionalColumn)->IndexDefinition.name,
          true,
        ),
      ],
      [],
      [(ChainId.fromInt(1337), false)],
    ))

    // The automatic index is the indexer's own, so finalizing must leave it be.
    sourceMock.resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=1000)
    await indexerMock.waitUntilReady()

    t.expect(
      (
        (await findIndexes(~tableName="A", ~columns=[optionalColumn]))->Array.length,
        (await findIndexes(~tableName="A", ~columns=["b_id"]))->Array.map(entry => entry.name),
        await readyAtByChainId(),
      ),
      ~message="Reaching ready adds the schema indexes without disturbing the automatic one",
    ).toEqual((1, [aBIdIndexName], [(ChainId.fromInt(1337), true)]))
  })
})
