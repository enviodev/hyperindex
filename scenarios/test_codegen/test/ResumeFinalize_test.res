open Vitest

let sql = PgStorage.makeClient()

let hasIndex = async definition => {
  let rows =
    (
      await sql->Postgres.unsafe(IndexCatalog.makeQuery(~pgSchema=Env.Db.publicSchema))
    )->S.parseOrThrow(IndexCatalog.rowsSchema)
  IndexCatalog.fromRows(~rows)->IndexCatalog.find(definition, ~coverage=Exact)->Option.isSome
}

let aBIdIndex = IndexDefinition.single(~tableName="A", ~column="b_id")

type persistedChain = {
  id: int,
  progressBlock: int,
  isReady: bool,
}

let persistedChains = async () => {
  let rows: array<{"id": int, "progress_block": int, "ready_at": Null.t<Date.t>}> =
    await sql->Postgres.unsafe(
      `SELECT "id", "progress_block", "ready_at" FROM "${Env.Db.publicSchema}"."envio_chains" ORDER BY "id";`,
    )
  rows->Array.map(row => {
    id: row["id"],
    progressBlock: row["progress_block"],
    isReady: row["ready_at"]->Null.toOption->Option.isSome,
  })
}

let clearReadyAt = async () => {
  let _ = await sql->Postgres.unsafe(
    `UPDATE "${Env.Db.publicSchema}"."envio_chains" SET "ready_at" = NULL;`,
  )
}

// Rejects the first `failCount` finalize attempts before delegating to the real
// implementation, standing in for a process that dies mid-transaction.
let makeFlakyFinalize = (~failCount) => {
  let calls = ref(0)
  let mapStorage = (storage: Persistence.storage) => {
    ...storage,
    finalizeBackfill: (~entities, ~chainIds, ~readyAt) => {
      calls := calls.contents + 1
      if calls.contents <= failCount {
        Promise.reject(Utils.Error.make("simulated crash before commit"))
      } else {
        storage.finalizeBackfill(~entities, ~chainIds, ~readyAt)
      }
    },
  }
  (calls, mapStorage)
}

describe("Resuming a backfill that never finalized", () => {
  // A run that persists its last batch and dies before finalizing leaves
  // progress at the head with ready_at unset and the schema indexes missing.
  // The resumed run has no batch to process and — since the head hasn't moved —
  // no source response to react to either, so readiness has to come from the
  // persisted progress/height alone.
  Async.it("Finalizes an open-ended chain without waiting for a new source block", async t => {
    let (finalizeCalls, mapStorage) = makeFlakyFinalize(~failCount=1)

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
      (finalizeCalls.contents, await persistedChains(), await hasIndex(aBIdIndex)),
      ~message="The first run reached the head, then died before committing anything",
    ).toEqual((1, [{id: 1337, progressBlock: 100, isReady: false}], false))

    let restarted = await indexerMock.restart()
    // No further height or items are resolved, and no block 101 is published.
    await restarted.waitUntilReady()

    t.expect(
      (
        finalizeCalls.contents,
        await persistedChains(),
        await hasIndex(aBIdIndex),
        await restarted.metric("envio_progress_ready"),
      ),
      ~message="The resumed run owes the schema its indexes even with no work left",
    ).toEqual((
      2,
      [{id: 1337, progressBlock: 100, isReady: true}],
      true,
      [{value: "1", labels: dict{"chainId": "1337"}}],
    ))
  })

  // Same crash, but "caught up" is the configured endBlock rather than a live
  // head — so the resumed run doesn't need a height response at all.
  Async.it("Finalizes a finite endBlock chain without waiting for a new source block", async t => {
    let (finalizeCalls, mapStorage) = makeFlakyFinalize(~failCount=1)

    let sourceMock = MockIndexer.Source.make(
      [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes],
      ~chain=#1337,
    )
    let indexerMock = await MockIndexer.Indexer.make(
      ~chains=[
        {chain: #1337, endBlock: 100, sourceConfig: Config.CustomSources([sourceMock.source])},
      ],
      ~shouldRollbackOnReorg=false,
      ~mapStorage,
      ~onError=_ => (),
      // A finite chain exits the process on success; keep the test worker alive.
      ~onExit=() => (),
    )
    await Utils.delay(0)

    sourceMock.resolveGetHeightOrThrow(100)
    await Utils.delay(0)
    await Utils.delay(0)
    sourceMock.resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=100)
    await indexerMock.getBatchWritePromise()

    t.expect(
      (finalizeCalls.contents, await persistedChains(), await hasIndex(aBIdIndex)),
      ~message="The first run reached its endBlock, then died before committing anything",
    ).toEqual((1, [{id: 1337, progressBlock: 100, isReady: false}], false))

    let restarted = await indexerMock.restart()
    await restarted.waitUntilReady()

    t.expect(
      (
        finalizeCalls.contents,
        await persistedChains(),
        await hasIndex(aBIdIndex),
        await restarted.metric("envio_progress_ready"),
      ),
      ~message="A chain at its endBlock is durably caught up on resume",
    ).toEqual((
      2,
      [{id: 1337, progressBlock: 100, isReady: true}],
      true,
      [{value: "1", labels: dict{"chainId": "1337"}}],
    ))
  })

  // Two chains at different heads: neither is allowed to hold finalization back
  // waiting for a source response, and readiness is stamped on both together.
  Async.it("Finalizes two open-ended chains caught up to different persisted heads", async t => {
    let (finalizeCalls, mapStorage) = makeFlakyFinalize(~failCount=1)

    let sourceMock1337 = MockIndexer.Source.make(
      [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes],
      ~chain=#1337,
    )
    let sourceMock1 = MockIndexer.Source.make(
      [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes],
      ~chain=#1,
    )
    let indexerMock = await MockIndexer.Indexer.make(
      ~chains=[
        {chain: #1337, sourceConfig: Config.CustomSources([sourceMock1337.source])},
        {chain: #1, sourceConfig: Config.CustomSources([sourceMock1.source])},
      ],
      ~shouldRollbackOnReorg=false,
      ~mapStorage,
      ~onError=_ => (),
    )
    await Utils.delay(0)

    sourceMock1337.resolveGetHeightOrThrow(100)
    sourceMock1.resolveGetHeightOrThrow(55)
    await Utils.delay(0)
    await Utils.delay(0)
    sourceMock1337.resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=100)
    sourceMock1.resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=55)
    await indexerMock.getBatchWritePromise()

    t.expect(
      (finalizeCalls.contents, await persistedChains(), await hasIndex(aBIdIndex)),
      ~message="Both chains reached their own head, then the run died before committing",
    ).toEqual((
      1,
      [{id: 1, progressBlock: 55, isReady: false}, {id: 1337, progressBlock: 100, isReady: false}],
      false,
    ))

    let restarted = await indexerMock.restart()
    await restarted.waitUntilReady()

    t.expect(
      (
        finalizeCalls.contents,
        await persistedChains(),
        await hasIndex(aBIdIndex),
        await restarted.metric("envio_progress_ready"),
      ),
      ~message="Each chain is measured against its own persisted head",
    ).toEqual((
      2,
      [{id: 1, progressBlock: 55, isReady: true}, {id: 1337, progressBlock: 100, isReady: true}],
      true,
      [{value: "1", labels: dict{"chainId": "1"}}, {value: "1", labels: dict{"chainId": "1337"}}],
    ))
  })

  // The head doesn't stand still while an indexer is down. The resumed run's
  // first height already reports blocks past the persisted progress, so nothing
  // about the live fetch frontier says "caught up" any more — but the indexes
  // owed for the progress that was committed can't wait out another backfill.
  Async.it("Finalizes a chain the head has already outrun by the time it resumes", async t => {
    let (finalizeCalls, mapStorage) = makeFlakyFinalize(~failCount=1)

    let sourceMock = MockIndexer.Source.make(
      [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes],
      ~chain=#1337,
    )
    // Once set, heights resolve on their own, so the resumed run learns the new
    // head before its processing loop builds a first batch.
    let movedHead = ref(None)
    let source = {
      ...sourceMock.source,
      getHeightOrThrow: () =>
        switch movedHead.contents {
        | Some(height) => Promise.resolve({Source.height, requestStats: []})
        | None => sourceMock.source.getHeightOrThrow()
        },
    }
    let indexerMock = await MockIndexer.Indexer.make(
      ~chains=[{chain: #1337, sourceConfig: Config.CustomSources([source])}],
      ~shouldRollbackOnReorg=false,
      ~mapStorage,
      ~onError=_ => (),
    )
    await Utils.delay(0)

    sourceMock.resolveGetHeightOrThrow(100)
    await Utils.delay(0)
    await Utils.delay(0)
    sourceMock.resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=100)
    await indexerMock.getBatchWritePromise()

    t.expect(
      (finalizeCalls.contents, await persistedChains(), await hasIndex(aBIdIndex)),
      ~message="The first run reached the head, then died before committing anything",
    ).toEqual((1, [{id: 1337, progressBlock: 100, isReady: false}], false))

    movedHead := Some(150)
    let restarted = await indexerMock.restart()
    await restarted.waitUntilReady()

    t.expect(
      (finalizeCalls.contents, await persistedChains(), await hasIndex(aBIdIndex)),
      ~message="Readiness is owed to the progress that was committed, not to the current head",
    ).toEqual((2, [{id: 1337, progressBlock: 100, isReady: true}], true))
  })

  // The indexes committed, then readiness was lost before it could be observed.
  // The resumed run has nothing to build and only has to stamp ready_at.
  Async.it("Stamps readiness without rebuilding indexes that already exist", async t => {
    let (finalizeCalls, mapStorage) = makeFlakyFinalize(~failCount=0)

    let sourceMock = MockIndexer.Source.make(
      [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes],
      ~chain=#1337,
    )
    let indexerMock = await MockIndexer.Indexer.make(
      ~chains=[{chain: #1337, sourceConfig: Config.CustomSources([sourceMock.source])}],
      ~shouldRollbackOnReorg=false,
      ~mapStorage,
      ~onError=_ => (),
    )
    await Utils.delay(0)

    sourceMock.resolveGetHeightOrThrow(100)
    await Utils.delay(0)
    await Utils.delay(0)
    sourceMock.resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=100)
    await indexerMock.getBatchWritePromise()
    await indexerMock.waitUntilReady()

    // Rewind only the readiness stamp, leaving the indexes the first run built.
    await clearReadyAt()

    t.expect(
      (finalizeCalls.contents, await persistedChains(), await hasIndex(aBIdIndex)),
      ~message="The indexes are in place but readiness is gone",
    ).toEqual((1, [{id: 1337, progressBlock: 100, isReady: false}], true))

    let restarted = await indexerMock.restart()
    await restarted.waitUntilReady()

    t.expect(
      (
        finalizeCalls.contents,
        await persistedChains(),
        await hasIndex(aBIdIndex),
        await restarted.metric("envio_progress_ready"),
      ),
      ~message="Finalizing over an already-indexed schema only stamps readiness",
    ).toEqual((
      2,
      [{id: 1337, progressBlock: 100, isReady: true}],
      true,
      [{value: "1", labels: dict{"chainId": "1337"}}],
    ))
  })
})
