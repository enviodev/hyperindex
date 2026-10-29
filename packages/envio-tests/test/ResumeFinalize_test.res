open Vitest

let schema = `
type A {
  id: ID!
  b: B! @index
}

type B {
  id: ID!
  a: [A!]! @derivedFrom(field: "b")
}
`

let contractsYaml = `
contracts:
  - name: Gravatar
    events:
      - event: "TestEvent()"
`

let chainYaml = (chainId, address, extra) =>
  `
  - id: ${chainId->Int.toString}
    rpc:
      url: https://rpc${chainId->Int.toString}.example.test
      for: sync
    start_block: 1${extra}
    contracts:
      - name: Gravatar
        address: "${address}"
`

let gravatar1337 = "0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3"
let gravatar1 = "0x3B2f78c5BF6D9C12Ee1225D5F374aa91204580c3"

let scenario = Scenario.make(
  ~supervised=false,
  ~configYaml=`
name: resume-finalize${contractsYaml}chains:${chainYaml(1337, gravatar1337, "")}`,
  ~schema,
)

let endBlockScenario = Scenario.make(
  ~supervised=false,
  ~configYaml=`
name: resume-finalize-end-block${contractsYaml}chains:${chainYaml(
      1337,
      gravatar1337,
      "\n    end_block: 100",
    )}`,
  ~schema,
)

let multichainScenario = Scenario.make(
  ~supervised=false,
  ~configYaml=`
name: resume-finalize-multichain${contractsYaml}chains:${chainYaml(1, gravatar1, "")}${chainYaml(
      1337,
      gravatar1337,
      "",
    )}`,
  ~schema,
)

let methods: array<MockSource.method> = [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes]

let aBIdIndex = "A_b_id_556h9mdu8a"

let hasIndex = async (name, ~sql, ~pgSchema) =>
  (await sql->PgCatalog.indexes(~pgSchema))->Array.some(index =>
    index.name === name && index.isValid
  )

type persistedChain = {
  id: int,
  progressBlock: int,
  isReady: bool,
}

let persistedChains = async (indexer: IndexerRunner.t) =>
  (await indexer.queryChains())->Array.map(chain => {
    id: chain.id->ChainId.toString->Int.fromString->Option.getOrThrow,
    progressBlock: chain.progressBlock,
    isReady: chain.readyAt->Option.isSome,
  })

let persistedReadyAt = async (indexer: IndexerRunner.t) =>
  (await indexer.queryChains())->Array.map(chain => chain.readyAt->Option.map(Date.toISOString))

let dropIndex = async (name, ~sql, ~pgSchema) => {
  let _ = await sql->Sql.queryForTests(`DROP INDEX "${pgSchema}"."${name}";`)
}

let clearReadyAt = async (~sql, ~pgSchema) => {
  let _ = await sql->Sql.queryForTests(`UPDATE "${pgSchema}"."envio_chains" SET "ready_at" = NULL;`)
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
  let (finalizeCalls, mapStorage) = makeFlakyFinalize(~failCount=1)

  scenario->Scenario.it(
    "Finalizes an open-ended chain without waiting for a new source block",
    ~sources=[{chain: 1337, methods}],
    ~mapStorage,
    // The simulated crash reaches the loop's error boundary; swallow it so it
    // doesn't take the test worker down with it.
    ~onError=_ => (),
    async (~t, ~indexer, ~source) => {
      let source = source(1337)
      let pgSchema = indexer.pgSchema

      source.resolveGetHeightOrThrow(100)
      await source.expectItemsQueries([
        {fromBlock: 1, reply: Respond({items: [], latestFetchedBlockNumber: 100})},
      ])
      await indexer.getBatchWritePromise()

      t.expect(
        (finalizeCalls.contents, await persistedChains(indexer)),
        ~message="The first run reached the head, then died before committing anything",
      ).toEqual((1, [{id: 1337, progressBlock: 100, isReady: false}]))
      await indexer.usePostgresSql(async sql =>
        t.expect(
          await hasIndex(aBIdIndex, ~sql, ~pgSchema),
          ~message="The first run died before committing the indexes",
        ).toBe(false)
      )

      let restarted = await indexer.restart()
      // No further height or items are resolved, and no block 101 is published.
      await restarted.waitUntilReady()

      t.expect(
        (
          finalizeCalls.contents,
          await persistedChains(restarted),
          await restarted.metric("envio_progress_ready"),
        ),
        ~message="The resumed run finalizes even with no work left",
      ).toEqual((
        2,
        [{id: 1337, progressBlock: 100, isReady: true}],
        [{value: "1", labels: dict{"chainId": "1337"}}],
      ))
      await restarted.usePostgresSql(async sql =>
        t.expect(
          await hasIndex(aBIdIndex, ~sql, ~pgSchema),
          ~message="The resumed run owes the schema its indexes even with no work left",
        ).toBe(true)
      )

      // Catching up here flips the chain to realtime, which changes the source
      // waitForNewBlock parks on. Fetching started before processing did, so the
      // waiter in flight is bound to the pre-realtime source and has to be
      // replaced rather than left to time out. A re-parked waiter is one the next
      // head still reaches, so answering the poll that follows the flip has to
      // put the chain back to work on the range it opened up.
      let heightCallsWhenReady = source.getHeightOrThrowCalls->Array.length
      await MockSource.waitHeightQuery(source, ~since=heightCallsWhenReady)
      source.resolveGetHeightOrThrow(200)
      await source.expectItemsQueries([{fromBlock: 101, reply: LeavePending}])

      t.expect(
        (
          source.pendingItemsQueries,
          source.getHeightOrThrowCalls->Array.length > heightCallsWhenReady,
        ),
        ~message="Finalizing on resume re-parks the fetch waiter on the realtime source",
      ).toEqual(([{partitionId: "0", fromBlock: 101, toBlock: Unbounded, retryCount: 0}], true))
    },
  )

  // Every restart used to clear the in-memory readiness timestamps, so an
  // indexer that had already finalized looked unready and built its indexes and
  // stamped `ready_at` again on every boot.
  let (finalizeCalls, mapStorage) = makeFlakyFinalize(~failCount=0)

  scenario->Scenario.it(
    "Leaves a restart that is already ready alone",
    ~sources=[{chain: 1337, methods}],
    ~mapStorage,
    // The simulated crash reaches the loop's error boundary; swallow it so it
    // doesn't take the test worker down with it.
    ~onError=_ => (),
    async (~t, ~indexer, ~source) => {
      let source = source(1337)

      source.resolveGetHeightOrThrow(100)
      await source.expectItemsQueries([
        {fromBlock: 1, reply: Respond({items: [], latestFetchedBlockNumber: 100})},
      ])
      await indexer.getBatchWritePromise()
      await indexer.waitUntilReady()

      let readyAtBefore = await persistedReadyAt(indexer)
      t.expect(
        (finalizeCalls.contents, await persistedChains(indexer)),
        ~message="The first run finalized normally",
      ).toEqual((1, [{id: 1337, progressBlock: 100, isReady: true}]))

      let restarted = await indexer.restart()
      await Utils.delay(50)

      t.expect(
        (
          finalizeCalls.contents,
          await persistedReadyAt(restarted),
          await restarted.metric("envio_progress_ready"),
        ),
        ~message="A restart inherits the readiness it already earned",
      ).toEqual((1, readyAtBefore, [{value: "1", labels: dict{"chainId": "1337"}}]))
    },
  )

  // A resumed run seeds its chains' caught-up timestamps from the database, and
  // a batch that progresses must not be read as "already realtime": the run is
  // past the head it committed, but the indexes it owes for that head are still
  // missing.
  let (finalizeCalls, mapStorage) = makeFlakyFinalize(~failCount=1)

  scenario->Scenario.it(
    "Finalizes after the resumed run processes a fresh block",
    ~sources=[{chain: 1337, methods}],
    ~mapStorage,
    ~onError=_ => (),
    async (~t, ~indexer, ~source) => {
      let source = source(1337)
      let pgSchema = indexer.pgSchema

      source.resolveGetHeightOrThrow(100)
      await source.expectItemsQueries([
        {fromBlock: 1, reply: Respond({items: [], latestFetchedBlockNumber: 100})},
      ])
      await indexer.getBatchWritePromise()

      t.expect(
        finalizeCalls.contents,
        ~message="The first run reached the head, then died before finalizing",
      ).toBe(1)
      await indexer.usePostgresSql(async sql =>
        t.expect(
          await hasIndex(aBIdIndex, ~sql, ~pgSchema),
          ~message="The first run died before committing the indexes",
        ).toBe(false)
      )

      let restarted = await indexer.restart()
      source.resolveGetHeightOrThrow(101)
      await source.expectItemsQueries([{fromBlock: 101, reply: Respond({items: []})}])
      await restarted.waitUntilReady()
      await restarted.waitUntilIdle()

      t.expect(
        (finalizeCalls.contents, await persistedChains(restarted)),
        ~message="A progressing batch doesn't excuse the finalization the resumed run still owes",
      ).toEqual((2, [{id: 1337, progressBlock: 101, isReady: true}]))
      await restarted.usePostgresSql(async sql =>
        t.expect(
          await hasIndex(aBIdIndex, ~sql, ~pgSchema),
          ~message="A progressing batch doesn't excuse the indexes the resumed run still owes",
        ).toBe(true)
      )
    },
  )

  // Same crash, but "caught up" is the configured endBlock rather than a live
  // head — so the resumed run doesn't need a height response at all.
  let (finalizeCalls, mapStorage) = makeFlakyFinalize(~failCount=1)

  endBlockScenario->Scenario.it(
    "Finalizes a finite endBlock chain without waiting for a new source block",
    ~sources=[{chain: 1337, methods}],
    ~mapStorage,
    // The simulated crash reaches the loop's error boundary; swallow it so it
    // doesn't take the test worker down with it.
    ~onError=_ => (),
    // A finite chain exits the process on success; keep the test worker alive.
    ~onExit=() => (),
    async (~t, ~indexer, ~source) => {
      let source = source(1337)
      let pgSchema = indexer.pgSchema

      source.resolveGetHeightOrThrow(100)
      await source.expectItemsQueries([
        {fromBlock: 1, reply: Respond({items: [], latestFetchedBlockNumber: 100})},
      ])
      await indexer.getBatchWritePromise()

      t.expect(
        (finalizeCalls.contents, await persistedChains(indexer)),
        ~message="The first run reached its endBlock, then died before committing anything",
      ).toEqual((1, [{id: 1337, progressBlock: 100, isReady: false}]))
      await indexer.usePostgresSql(async sql =>
        t.expect(
          await hasIndex(aBIdIndex, ~sql, ~pgSchema),
          ~message="The first run died before committing the indexes",
        ).toBe(false)
      )

      let restarted = await indexer.restart()
      await restarted.waitUntilReady()

      t.expect(
        (
          finalizeCalls.contents,
          await persistedChains(restarted),
          await restarted.metric("envio_progress_ready"),
        ),
        ~message="A chain at its endBlock is durably caught up on resume",
      ).toEqual((
        2,
        [{id: 1337, progressBlock: 100, isReady: true}],
        [{value: "1", labels: dict{"chainId": "1337"}}],
      ))
      await restarted.usePostgresSql(async sql =>
        t.expect(
          await hasIndex(aBIdIndex, ~sql, ~pgSchema),
          ~message="A chain at its endBlock gets its indexes on resume",
        ).toBe(true)
      )
    },
  )

  // Two chains at different heads: neither is allowed to hold finalization back
  // waiting for a source response, and readiness is stamped on both together.
  let (finalizeCalls, mapStorage) = makeFlakyFinalize(~failCount=1)

  multichainScenario->Scenario.it(
    "Finalizes two open-ended chains caught up to different persisted heads",
    ~sources=[{chain: 1, methods}, {chain: 1337, methods}],
    ~mapStorage,
    // The simulated crash reaches the loop's error boundary; swallow it so it
    // doesn't take the test worker down with it.
    ~onError=_ => (),
    async (~t, ~indexer, ~source) => {
      let source1 = source(1)
      let source1337 = source(1337)
      let pgSchema = indexer.pgSchema

      source1337.resolveGetHeightOrThrow(100)
      source1.resolveGetHeightOrThrow(55)
      await source1337.expectItemsQueries([
        {fromBlock: 1, reply: Respond({items: [], latestFetchedBlockNumber: 100})},
      ])
      await source1.expectItemsQueries([
        {fromBlock: 1, reply: Respond({items: [], latestFetchedBlockNumber: 55})},
      ])
      await indexer.getBatchWritePromise()

      t.expect(
        (finalizeCalls.contents, await persistedChains(indexer)),
        ~message="Both chains reached their own head, then the run died before committing",
      ).toEqual((
        1,
        [
          {id: 1, progressBlock: 55, isReady: false},
          {id: 1337, progressBlock: 100, isReady: false},
        ],
      ))
      await indexer.usePostgresSql(async sql =>
        t.expect(
          await hasIndex(aBIdIndex, ~sql, ~pgSchema),
          ~message="The run died before committing the indexes",
        ).toBe(false)
      )

      let restarted = await indexer.restart()
      await restarted.waitUntilReady()

      t.expect(
        (
          finalizeCalls.contents,
          await persistedChains(restarted),
          await restarted.metric("envio_progress_ready"),
        ),
        ~message="Each chain is measured against its own persisted head",
      ).toEqual((
        2,
        [{id: 1, progressBlock: 55, isReady: true}, {id: 1337, progressBlock: 100, isReady: true}],
        [{value: "1", labels: dict{"chainId": "1"}}, {value: "1", labels: dict{"chainId": "1337"}}],
      ))
      await restarted.usePostgresSql(async sql =>
        t.expect(
          await hasIndex(aBIdIndex, ~sql, ~pgSchema),
          ~message="The resumed run commits the indexes",
        ).toBe(true)
      )
    },
  )

  // The head doesn't stand still while an indexer is down. The resumed run's
  // first height already reports blocks past the persisted progress, so nothing
  // about the live fetch frontier says "caught up" any more — but the indexes
  // owed for the progress that was committed can't wait out another backfill.
  let (finalizeCalls, mapStorage) = makeFlakyFinalize(~failCount=1)
  scenario->Scenario.it(
    "Finalizes a chain the head has already outrun by the time it resumes",
    ~sources=[{chain: 1337, methods}],
    ~mapStorage,
    // The simulated crash reaches the loop's error boundary; swallow it so it
    // doesn't take the test worker down with it.
    ~onError=_ => (),
    async (~t, ~indexer, ~source) => {
      let source = source(1337)
      let pgSchema = indexer.pgSchema

      source.resolveGetHeightOrThrow(100)
      await source.expectItemsQueries([
        {fromBlock: 1, reply: Respond({items: [], latestFetchedBlockNumber: 100})},
      ])
      await indexer.getBatchWritePromise()

      t.expect(
        (finalizeCalls.contents, await persistedChains(indexer)),
        ~message="The first run reached the head, then died before committing anything",
      ).toEqual((1, [{id: 1337, progressBlock: 100, isReady: false}]))
      await indexer.usePostgresSql(async sql =>
        t.expect(
          await hasIndex(aBIdIndex, ~sql, ~pgSchema),
          ~message="The first run died before committing the indexes",
        ).toBe(false)
      )

      // From here the source answers height calls on its own, so the resumed
      // run learns the new head before its processing loop builds a batch.
      source.setAutoHeight(150)
      let restarted = await indexer.restart()
      await restarted.waitUntilReady()

      t.expect(
        (finalizeCalls.contents, await persistedChains(restarted)),
        ~message="Readiness is owed to the progress that was committed, not to the current head",
      ).toEqual((2, [{id: 1337, progressBlock: 100, isReady: true}]))
      await restarted.usePostgresSql(async sql =>
        t.expect(
          await hasIndex(aBIdIndex, ~sql, ~pgSchema),
          ~message="The indexes are owed to the progress that was committed",
        ).toBe(true)
      )
    },
  )

  // The indexes committed, then readiness was lost before it could be observed.
  // The resumed run has nothing to build and only has to stamp ready_at.
  let (finalizeCalls, mapStorage) = makeFlakyFinalize(~failCount=0)

  scenario->Scenario.it(
    "Stamps readiness without rebuilding indexes that already exist",
    ~unsupported=[
      {
        backend: #clickhouse,
        reason: "clears envio_chains' ready_at with Postgres SQL, which a run keeping no entity in Postgres skips",
      },
    ],
    ~sources=[{chain: 1337, methods}],
    ~mapStorage,
    // The simulated crash reaches the loop's error boundary; swallow it so it
    // doesn't take the test worker down with it.
    ~onError=_ => (),
    async (~t, ~indexer, ~source) => {
      let source = source(1337)
      let pgSchema = indexer.pgSchema

      source.resolveGetHeightOrThrow(100)
      await source.expectItemsQueries([
        {fromBlock: 1, reply: Respond({items: [], latestFetchedBlockNumber: 100})},
      ])
      await indexer.getBatchWritePromise()
      await indexer.waitUntilReady()

      // Rewind only the readiness stamp, leaving the indexes the first run built.
      await indexer.usePostgresSql(sql => clearReadyAt(~sql, ~pgSchema))

      t.expect(
        (finalizeCalls.contents, await persistedChains(indexer)),
        ~message="Readiness is gone",
      ).toEqual((1, [{id: 1337, progressBlock: 100, isReady: false}]))
      await indexer.usePostgresSql(async sql =>
        t.expect(
          await hasIndex(aBIdIndex, ~sql, ~pgSchema),
          ~message="The indexes are in place",
        ).toBe(true)
      )

      let restarted = await indexer.restart()
      await restarted.waitUntilReady()

      t.expect(
        (
          finalizeCalls.contents,
          await persistedChains(restarted),
          await restarted.metric("envio_progress_ready"),
        ),
        ~message="Finalizing over an already-indexed schema only stamps readiness",
      ).toEqual((
        2,
        [{id: 1337, progressBlock: 100, isReady: true}],
        [{value: "1", labels: dict{"chainId": "1337"}}],
      ))
      await restarted.usePostgresSql(async sql =>
        t.expect(
          await hasIndex(aBIdIndex, ~sql, ~pgSchema),
          ~message="The indexes the first run built are kept",
        ).toBe(true)
      )
    },
  )

  // Durable readiness means an already-ready indexer never runs the finalize
  // pass again, so that pass can no longer be what notices an index the schema
  // promises going missing. Something else has to.
  let (finalizeCalls, mapStorage) = makeFlakyFinalize(~failCount=0)

  scenario->Scenario.it(
    "Rebuilds a schema index the database lost while it was down",
    ~unsupported=[
      {
        backend: #clickhouse,
        reason: "drops an index off a Postgres entity table, which the ClickHouse leg has none of",
      },
    ],
    ~sources=[{chain: 1337, methods}],
    ~mapStorage,
    // The simulated crash reaches the loop's error boundary; swallow it so it
    // doesn't take the test worker down with it.
    ~onError=_ => (),
    async (~t, ~indexer, ~source) => {
      let source = source(1337)
      let pgSchema = indexer.pgSchema

      source.resolveGetHeightOrThrow(100)
      await source.expectItemsQueries([
        {fromBlock: 1, reply: Respond({items: [], latestFetchedBlockNumber: 100})},
      ])
      await indexer.getBatchWritePromise()
      await indexer.waitUntilReady()

      await indexer.usePostgresSql(async sql => {
        let readyAtBefore = await persistedReadyAt(indexer)
        await dropIndex(aBIdIndex, ~sql, ~pgSchema)
        t.expect(
          (finalizeCalls.contents, await hasIndex(aBIdIndex, ~sql, ~pgSchema)),
          ~message="The index is gone but the chain is still stamped ready",
        ).toEqual((1, false))

        let restarted = await indexer.restart()
        await restarted.waitUntilReady()
        // The repair runs alongside indexing rather than blocking the loop, so it
        // isn't done by the time readiness is observable.
        let attempts = ref(0)
        while !(await hasIndex(aBIdIndex, ~sql, ~pgSchema)) && attempts.contents < 100 {
          attempts := attempts.contents + 1
          await Utils.delay(10)
        }

        t.expect(
          (
            finalizeCalls.contents,
            await hasIndex(aBIdIndex, ~sql, ~pgSchema),
            await persistedReadyAt(restarted),
          ),
          ~message="The index is restored without re-running finalization or moving readiness",
        ).toEqual((1, true, readyAtBefore))
      })
    },
  )

  // The realtime handoff bumps the epoch, which makes every in-flight response
  // stale. A response discarded that way never reaches handleQueryResult, so the
  // query it belonged to has to be retired here or its partition stops asking
  // for ranges at all.
  // Holds the second finalize open so the catch-up query below is provably
  // in flight when the handoff bumps the epoch — the window the leak needs.
  let gate = MockSource.Gate.make()
  let finalizeCalls = ref(0)
  let mapStorage = (storage: Persistence.storage) => {
    ...storage,
    finalizeBackfill: (~entities, ~chainIds, ~readyAt) => {
      finalizeCalls := finalizeCalls.contents + 1
      if finalizeCalls.contents == 1 {
        Promise.reject(Utils.Error.make("simulated crash before commit"))
      } else {
        gate.wait()->Promise.then(() => storage.finalizeBackfill(~entities, ~chainIds, ~readyAt))
      }
    },
  }
  scenario->Scenario.it(
    "Keeps fetching after the resume handoff discards an in-flight query",
    ~sources=[{chain: 1337, methods}],
    ~mapStorage,
    // The simulated crash reaches the loop's error boundary; swallow it so it
    // doesn't take the test worker down with it.
    ~onError=_ => (),
    async (~t, ~indexer, ~source) => {
      let source = source(1337)

      source.resolveGetHeightOrThrow(100)
      await source.expectItemsQueries([
        {fromBlock: 1, reply: Respond({items: [], latestFetchedBlockNumber: 100})},
      ])
      await indexer.getBatchWritePromise()

      t.expect(
        (finalizeCalls.contents, await persistedChains(indexer)),
        ~message="The first run reached the head, then died before committing anything",
      ).toEqual((1, [{id: 1337, progressBlock: 100, isReady: false}]))

      // From here the source answers height calls on its own, so the resumed
      // run learns the new head before its processing loop builds a batch.
      source.setAutoHeight(150)
      let restarted = await indexer.restart()

      // The resumed run sees head 150 and queries 101-150 while finalize is still
      // parked on the gate.
      await source.expectItemsQueries([{fromBlock: 101, reply: LeavePending}])
      await Scenario.waitUntil(
        () => gate.entered.contents === 1,
        ~message="the resumed run's finalize to reach the gate",
      )
      t.expect(
        (finalizeCalls.contents, source.pendingItemsQueries),
        ~message="A catch-up query is in flight while finalization is still open",
      ).toEqual((2, [{partitionId: "0", fromBlock: 101, toBlock: Unbounded, retryCount: 0}]))

      // Hold the query itself: the handoff replaces it with one carrying an
      // identical payload, and only this one's response is the discarded one.
      let discarded = source.pendingItemsQueries->Array.getUnsafe(0)

      gate.release()
      await restarted.waitUntilReady()

      // Issued under the old epoch, so the response is dropped before
      // handleQueryResult can retire it. Blocks 101-150 are still owed; a
      // partition left holding the discarded query would never ask for them again.
      await source.expectItemsQueries([
        {
          where: query => query === discarded,
          reply: Respond({items: [], latestFetchedBlockNumber: 150}),
        },
        {where: query => query !== discarded, fromBlock: 101, reply: LeavePending},
      ])
      t.expect(
        source.pendingItemsQueries,
        ~message="A discarded response must not leave the partition holding a pending query",
      ).toEqual([{partitionId: "0", fromBlock: 101, toBlock: Unbounded, retryCount: 0}])
    },
  )

  // A chain added to an already-synced indexer resumes with `ready_at` on every
  // other chain and none of its own, so finalization runs over a mix.
  let (finalizeCalls, mapStorage) = makeFlakyFinalize(~failCount=0)

  multichainScenario->Scenario.it(
    "Leaves the timestamps of already-ready chains alone",
    ~unsupported=[
      {
        backend: #clickhouse,
        reason: "clears chain 1337's ready_at with Postgres SQL, which a run keeping no entity in Postgres skips",
      },
    ],
    ~sources=[{chain: 1, methods}, {chain: 1337, methods}],
    ~mapStorage,
    // The simulated crash reaches the loop's error boundary; swallow it so it
    // doesn't take the test worker down with it.
    ~onError=_ => (),
    async (~t, ~indexer, ~source) => {
      let source1 = source(1)
      let source1337 = source(1337)

      source1337.resolveGetHeightOrThrow(100)
      source1.resolveGetHeightOrThrow(55)
      await source1337.expectItemsQueries([
        {fromBlock: 1, reply: Respond({items: [], latestFetchedBlockNumber: 100})},
      ])
      await source1.expectItemsQueries([
        {fromBlock: 1, reply: Respond({items: [], latestFetchedBlockNumber: 55})},
      ])
      await indexer.getBatchWritePromise()
      await indexer.waitUntilReady()

      // Stand in for a chain joining a synced indexer: chain 1 keeps the stamp it
      // earned, chain 1337 arrives without one.
      await indexer.usePostgresSql(async sql => {
        let _ = await sql->Sql.queryForTests(
          `UPDATE "${indexer.pgSchema}"."envio_chains" SET "ready_at" = NULL WHERE "id" = 1337;`,
        )
      })
      let readyAtBefore = await persistedReadyAt(indexer)
      t.expect(
        (finalizeCalls.contents, await persistedChains(indexer)),
        ~message="Only chain 1337 is missing its stamp",
      ).toEqual((
        1,
        [{id: 1, progressBlock: 55, isReady: true}, {id: 1337, progressBlock: 100, isReady: false}],
      ))

      let restarted = await indexer.restart()
      await restarted.waitUntilReady()

      let readyAtAfter = await persistedReadyAt(restarted)
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
    },
  )
})
