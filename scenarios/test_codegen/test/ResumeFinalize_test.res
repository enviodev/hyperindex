open Vitest

let sql = PgStorage.makeClient()

let hasIndex = async definition => {
  let rows =
    (
      await sql->Postgres.unsafe(IndexCatalog.makeQuery(~pgSchema=Env.Db.publicSchema))
    )->S.parseOrThrow(IndexCatalog.rowsSchema)
  IndexCatalog.fromRows(~rows)->IndexCatalog.find(definition)->Option.isSome
}

let aBIdIndex = IndexDefinition.single(~tableName="A", ~column="b_id")

let isReadyInDb = async () => {
  let rows: array<{"ready_at": Null.t<Date.t>}> =
    await sql->Postgres.unsafe(
      `SELECT "ready_at" FROM "${Env.Db.publicSchema}"."envio_chains" WHERE "id" = 1337;`,
    )
  switch rows->Array.get(0) {
  | Some(row) => row["ready_at"]->Null.toOption->Option.isSome
  | None => false
  }
}

describe("Resuming a backfill that never finalized", () => {
  // Chain 1337 has no endBlock, so "caught up" means reached the live head.
  // A run that persists its last batch and dies before finalizing leaves
  // progress at the head with ready_at unset and the schema indexes missing —
  // and the resumed run has no batch to process, which is the case that has to
  // still reach ready.
  Async.it("Finalizes even though the resumed run has nothing left to process", async t => {
    let failFinalize = ref(true)
    let finalizeCalls = ref(0)
    let mapStorage = (storage: Persistence.storage) => {
      ...storage,
      finalizeBackfill: (~entities, ~chainIds, ~readyAt) => {
        finalizeCalls := finalizeCalls.contents + 1
        if failFinalize.contents {
          // Stands in for the process dying mid-transaction: nothing commits.
          Promise.reject(Utils.Error.make("simulated crash before commit"))
        } else {
          storage.finalizeBackfill(~entities, ~chainIds, ~readyAt)
        }
      },
    }

    let sourceMock = MockIndexer.Source.make(
      [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes],
      ~chain=#1337,
    )
    let indexerMock = await MockIndexer.Indexer.make(
      ~chains=[{chain: #1337, sourceConfig: Config.CustomSources([sourceMock.source])}],
      ~shouldRollbackOnReorg=false,
      ~mapStorage,
      // The simulated crash reaches the loop's error boundary; swallow it so it
      // doesn't take the test worker down with it.
      ~onError=_ => (),
    )
    await Utils.delay(0)

    sourceMock.resolveGetHeightOrThrow(100)
    await Utils.delay(0)
    await Utils.delay(0)
    sourceMock.resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=100)
    await indexerMock.getBatchWritePromise()

    t.expect(
      (finalizeCalls.contents, await isReadyInDb(), await hasIndex(aBIdIndex)),
      ~message="The first run reached the head, then died before committing anything",
    ).toEqual((1, false, false))

    failFinalize := false
    let restarted = await indexerMock.restart()
    await Utils.delay(0)

    // The head hasn't moved: progress is already at 100, so there is nothing to
    // fetch and no batch to process.
    sourceMock.resolveGetHeightOrThrow(100)
    await Utils.delay(0)
    await Utils.delay(0)
    await restarted.getBatchWritePromise()

    t.expect(
      (
        finalizeCalls.contents,
        await isReadyInDb(),
        await hasIndex(aBIdIndex),
        await restarted.metric("envio_progress_ready"),
      ),
      ~message="The resumed run owes the schema its indexes even with no work left",
    ).toEqual((
      2,
      true,
      true,
      [{value: "1", labels: dict{"chainId": "1337"}}],
    ))
  })
})
