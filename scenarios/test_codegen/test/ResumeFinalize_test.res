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

let persistedReadyAt = async () => {
  let rows: array<{"ready_at": Null.t<Date.t>}> =
    await sql->Postgres.unsafe(
      `SELECT "ready_at" FROM "${Env.Db.publicSchema}"."envio_chains" ORDER BY "id";`,
    )
  rows->Array.map(row => row["ready_at"]->Null.toOption->Option.map(Date.toISOString))
}

let dropIndex = async definition => {
  let _ = await sql->Postgres.unsafe(
    `DROP INDEX "${Env.Db.publicSchema}"."${definition->IndexDefinition.name}";`,
  )
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
      ~chainId=#1337,
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

    // Catching up here flips the chain to realtime, which changes the source
    // waitForNewBlock parks on. Fetching started before processing did, so the
    // waiter in flight is bound to the pre-realtime source and has to be
    // replaced rather than left to time out. Counts unresolved calls across both
    // runs: 3 are parked without the handoff, the 4th is the re-parked waiter.
    t.expect(
      sourceMock.getHeightOrThrowCalls->Array.length,
      ~message="Finalizing on resume re-parks the fetch waiter on the realtime source",
    ).toEqual(4)

    await restarted.stop()
  })

  // Every restart used to clear the in-memory readiness timestamps, so an
  // indexer that had already finalized looked unready and built its indexes and
  // stamped `ready_at` again on every boot.
  Async.it("Leaves a restart that is already ready alone", async t => {
    let (finalizeCalls, mapStorage) = makeFlakyFinalize(~failCount=0)

    let sourceMock = MockIndexer.Source.make(
      [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes],
      ~chainId=#1337,
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

    let readyAtBefore = await persistedReadyAt()
    t.expect(
      (finalizeCalls.contents, await persistedChains()),
      ~message="The first run finalized normally",
    ).toEqual((1, [{id: 1337, progressBlock: 100, isReady: true}]))

    let restarted = await indexerMock.restart()
    await Utils.delay(50)

    t.expect(
      (finalizeCalls.contents, await persistedReadyAt(), await restarted.metric("envio_progress_ready")),
      ~message="A restart inherits the readiness it already earned",
    ).toEqual((1, readyAtBefore, [{value: "1", labels: dict{"chainId": "1337"}}]))

    await restarted.stop()
  })

  // Same crash, but "caught up" is the configured endBlock rather than a live
  // head — so the resumed run doesn't need a height response at all.
  Async.it("Finalizes a finite endBlock chain without waiting for a new source block", async t => {
    let (finalizeCalls, mapStorage) = makeFlakyFinalize(~failCount=1)

    let sourceMock = MockIndexer.Source.make(
      [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes],
      ~chainId=#1337,
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

    await restarted.stop()
  })

  // Two chains at different heads: neither is allowed to hold finalization back
  // waiting for a source response, and readiness is stamped on both together.
  Async.it("Finalizes two open-ended chains caught up to different persisted heads", async t => {
    let (finalizeCalls, mapStorage) = makeFlakyFinalize(~failCount=1)

    let sourceMock1337 = MockIndexer.Source.make(
      [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes],
      ~chainId=#1337,
    )
    let sourceMock1 = MockIndexer.Source.make(
      [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes],
      ~chainId=#1,
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

    await restarted.stop()
  })

  // The head doesn't stand still while an indexer is down. The resumed run's
  // first height already reports blocks past the persisted progress, so nothing
  // about the live fetch frontier says "caught up" any more — but the indexes
  // owed for the progress that was committed can't wait out another backfill.
  Async.it("Finalizes a chain the head has already outrun by the time it resumes", async t => {
    let (finalizeCalls, mapStorage) = makeFlakyFinalize(~failCount=1)

    let sourceMock = MockIndexer.Source.make(
      [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes],
      ~chainId=#1337,
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

    await restarted.stop()
  })

  // The indexes committed, then readiness was lost before it could be observed.
  // The resumed run has nothing to build and only has to stamp ready_at.
  Async.it("Stamps readiness without rebuilding indexes that already exist", async t => {
    let (finalizeCalls, mapStorage) = makeFlakyFinalize(~failCount=0)

    let sourceMock = MockIndexer.Source.make(
      [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes],
      ~chainId=#1337,
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

    await restarted.stop()
  })

  // Durable readiness means an already-ready indexer never runs the finalize
  // pass again, so that pass can no longer be what notices an index the schema
  // promises going missing. Something else has to.
  Async.it("Rebuilds a schema index the database lost while it was down", async t => {
    let (finalizeCalls, mapStorage) = makeFlakyFinalize(~failCount=0)

    let sourceMock = MockIndexer.Source.make(
      [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes],
      ~chainId=#1337,
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

    let readyAtBefore = await persistedReadyAt()
    await dropIndex(aBIdIndex)
    t.expect(
      (finalizeCalls.contents, await hasIndex(aBIdIndex)),
      ~message="The index is gone but the chain is still stamped ready",
    ).toEqual((1, false))

    let restarted = await indexerMock.restart()
    await restarted.waitUntilReady()
    // The repair runs alongside indexing rather than blocking the loop, so it
    // isn't done by the time readiness is observable.
    let attempts = ref(0)
    while !(await hasIndex(aBIdIndex)) && attempts.contents < 100 {
      attempts := attempts.contents + 1
      await Utils.delay(10)
    }

    t.expect(
      (finalizeCalls.contents, await hasIndex(aBIdIndex), await persistedReadyAt()),
      ~message="The index is restored without re-running finalization or moving readiness",
    ).toEqual((1, true, readyAtBefore))

    await restarted.stop()
  })

  // The realtime handoff bumps the epoch, which makes every in-flight response
  // stale. A response discarded that way never reaches handleQueryResult, so the
  // query it belonged to has to be retired here or its partition stops asking
  // for ranges at all.
  Async.it("Keeps fetching after the resume handoff discards an in-flight query", async t => {
    // Holds the second finalize open so the catch-up query below is provably
    // in flight when the handoff bumps the epoch — the window the leak needs.
    let gate = MockIndexer.Gate.make()
    let finalizeCalls = ref(0)
    let mapStorage = (storage: Persistence.storage) => {
      ...storage,
      finalizeBackfill: (~entities, ~chainIds, ~readyAt) => {
        finalizeCalls := finalizeCalls.contents + 1
        if finalizeCalls.contents == 1 {
          Promise.reject(Utils.Error.make("simulated crash before commit"))
        } else {
          gate.wait()->Promise.then(() =>
            storage.finalizeBackfill(~entities, ~chainIds, ~readyAt)
          )
        }
      },
    }

    let sourceMock = MockIndexer.Source.make(
      [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes],
      ~chainId=#1337,
    )
    // The resumed run learns a moved head on its own, so it dispatches a
    // catch-up query while the finalize pass is still awaiting its indexes.
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
      (finalizeCalls.contents, await persistedChains()),
      ~message="The first run reached the head, then died before committing anything",
    ).toEqual((1, [{id: 1337, progressBlock: 100, isReady: false}]))

    movedHead := Some(150)
    let restarted = await indexerMock.restart()

    // The resumed run sees head 150 and queries 101-150 while finalize is still
    // parked on the gate.
    let attempts = ref(0)
    while sourceMock.getItemsOrThrowCalls->Utils.Array.isEmpty && attempts.contents < 200 {
      attempts := attempts.contents + 1
      await Utils.delay(5)
    }
    t.expect(
      (finalizeCalls.contents, sourceMock.getItemsOrThrowCalls->Array.length),
      ~message="A catch-up query is in flight while finalization is still open",
    ).toEqual((2, 1))

    gate.release()
    await restarted.waitUntilReady()

    // That query was issued under the old epoch, so its response is dropped
    // before handleQueryResult can retire it.
    sourceMock.resolveGetItemsOrThrow([], ~resolveAt=#first, ~latestFetchedBlockNumber=150)
    let attempts = ref(0)
    while sourceMock.getItemsOrThrowCalls->Utils.Array.isEmpty && attempts.contents < 200 {
      attempts := attempts.contents + 1
      await Utils.delay(5)
    }

    // Blocks 101-150 are still owed; a partition left holding the discarded
    // query would never ask for them again.
    t.expect(
      sourceMock.getItemsOrThrowCalls->Utils.Array.notEmpty,
      ~message="A discarded response must not leave the partition holding a pending query",
    ).toEqual(true)

    await restarted.stop()
  })

  // A chain added to an already-synced indexer resumes with `ready_at` on every
  // other chain and none of its own, so finalization runs over a mix.
  Async.it("Leaves the timestamps of already-ready chains alone", async t => {
    let (finalizeCalls, mapStorage) = makeFlakyFinalize(~failCount=0)

    let sourceMock1337 = MockIndexer.Source.make(
      [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes],
      ~chainId=#1337,
    )
    let sourceMock1 = MockIndexer.Source.make(
      [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes],
      ~chainId=#1,
    )
    let chains: array<MockIndexer.Indexer.chainConfig> = [
      {chain: #1337, sourceConfig: Config.CustomSources([sourceMock1337.source])},
      {chain: #1, sourceConfig: Config.CustomSources([sourceMock1.source])},
    ]
    let indexerMock = await MockIndexer.Indexer.make(
      ~chains,
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
    await indexerMock.waitUntilReady()

    // Stand in for a chain joining a synced indexer: chain 1 keeps the stamp it
    // earned, chain 1337 arrives without one.
    let _ = await sql->Postgres.unsafe(
      `UPDATE "${Env.Db.publicSchema}"."envio_chains" SET "ready_at" = NULL WHERE "id" = 1337;`,
    )
    let readyAtBefore = await persistedReadyAt()
    t.expect(
      (finalizeCalls.contents, await persistedChains()),
      ~message="Only chain 1337 is missing its stamp",
    ).toEqual((
      1,
      [{id: 1, progressBlock: 55, isReady: true}, {id: 1337, progressBlock: 100, isReady: false}],
    ))

    let restarted = await indexerMock.restart()
    await restarted.waitUntilReady()

    let readyAtAfter = await persistedReadyAt()
    t.expect(
      (
        finalizeCalls.contents,
        readyAtAfter->Array.get(0),
        readyAtAfter->Array.get(1)->Option.map(Option.isSome),
        await restarted.metric("envio_progress_ready"),
      ),
      ~message="Chain 1 keeps the timestamp it first caught up at; only 1337 is stamped",
    ).toEqual((
      2,
      readyAtBefore->Array.get(0),
      Some(true),
      [{value: "1", labels: dict{"chainId": "1"}}, {value: "1", labels: dict{"chainId": "1337"}}],
    ))

    await restarted.stop()
  })
})
