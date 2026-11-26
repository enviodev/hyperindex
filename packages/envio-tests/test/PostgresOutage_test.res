open Vitest

// A database restart, a failover or a pooler in front of either drops the
// indexer's connections mid-run. What is safe to send again — a load, the
// chain metadata upsert, a batch that never reached COMMIT — is sent again once
// the database answers, for up to a minute, rather than ending the run.
let proxyPort = 18563

let outageRef = ref(None)
Async.beforeAll(async () => {
  outageRef := Some(await PostgresOutage.start(~port=proxyPort, ~upstreamPort=IndexerEnv.read().db.port))
})
Async.afterAll(async () =>
  switch outageRef.contents {
  | Some(outage) => await outage.close()
  | None => ()
  }
)

// Up at the start of every test, whatever the one before it left behind.
//
// The proxy refusing a connection is real socket I/O. An `advanceTime(0)` right
// after `goDown` waits on it the way it waits on any write in flight, so the
// attempt has failed, and armed its retry, before the test moves on.
let outageWithDatabaseUp = () => {
  let outage = outageRef.contents->Option.getOrThrow
  outage.comeBack()
  outage
}

let scenario = Scenario.make(
  ~configYaml=`
name: postgres-outage
chains:
  - id: 1337
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 1
    contracts:
      - name: Gravatar
        address: "0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3"
        events:
          - event: "TestEvent()"
`,
  ~schema=`
type Tally {
  id: ID!
  count: Float!
}
`,
  ~unsupported=Scenario.noClickHouse(
    "a batch that reached ClickHouse before Postgres lost its connection is resumed rather than written again",
  ),
)

type tally = {id: string, count: float}
type tallyOps = {get: string => promise<option<tally>>, set: tally => unit}
type handlerContext = {@as("Tally") tally: tallyOps}

let contextOf = (args: Internal.handlerArgs) =>
  args.context->(Utils.magic: Internal.handlerContext => handlerContext)

// The handler waits for `handled` before it counts, so a test can let what the
// response staged land first and take the database away from what follows.
// Without `~load` it counts from zero, so nothing but the write needs the
// database.
let replyWithOneTally = async (source: MockSource.t, ~handled, ~load=true) =>
  await source.expectItemsQueries([
    {
      fromBlock: 1,
      toBlock: Unbounded,
      reply: Respond({
        items: [
          {
            blockNumber: 1,
            logIndex: 0,
            handler: async args => {
              await handled
              let tally = (args->contextOf).tally
              let count = load ? (await tally.get("1"))->Option.mapOr(0., tally => tally.count) : 0.
              tally.set({id: "1", count: count +. 1.})
            },
          },
        ],
        latestFetchedBlockNumber: 50,
        knownHeight: 100,
      }),
    },
  ])

let makeHeldHandler = () => {
  let release = ref(ignore)
  let handled = Promise.make((resolve, _) => release := resolve)
  (handled, () => release.contents())
}

// Which operations were sent again, once each.
let retriedOperations = (indexer: IndexerRunner.t) =>
  indexer.infoAndAboveLogs()
  ->Array.filterMap(({msg, params}) =>
    msg == ConnectionRetry.lostConnectionMsg
      ? switch params->Dict.get("operation") {
        | Some(String(operation)) => Some(operation)
        | _ => None
        }
      : None
  )
  ->Set.fromArray
  ->Set.values
  ->Array.fromIterator

// Other test files share the server, each in a schema of its own, so a lock
// wait counts only when its statement names this run's schema.
let lockWaitersOf = (indexer: IndexerRunner.t) =>
  `FROM pg_stat_activity WHERE wait_event_type = 'Lock' AND query LIKE '%"${indexer.pgSchema}"%'`

// Cuts the batch's COMMIT and holds it back until the batch, looked for and not
// found, is written again and waits on the held transaction's rows. Releasing
// the returned gate lets the COMMIT reach the server, or with `~deliver=false`
// drops it.
let holdCommitUntilRewriteBlocks = async (
  indexer: IndexerRunner.t,
  ~outage: PostgresOutage.t,
  ~releaseHandler,
  ~deliver,
) => {
  let commitArrives = MockSource.Gate.make()
  outage.cutNextCommit(~deliver, ~holdUntil=commitArrives.wait())
  releaseHandler()
  await indexer.advanceTime(0)
  await indexer.advanceTime(5_000)
  await indexer.usePostgresSql(async sql => {
    let rec waitForBlockedRewrite = async (~attempts) => {
      let waiting =
        (
          await sql->StorageClient.queryForTests(
            `SELECT count(*)::int AS waiting ${indexer->lockWaitersOf}`,
          )
        )->Array.map(row => row->Dict.getUnsafe("waiting")->(Utils.magic: unknown => int))
      switch waiting {
      | [count] if count > 0 => ()
      | _ if attempts > 0 =>
        // Real time: the batch is looked for and written again over the
        // network, off the indexer's clock.
        await Utils.delay(10)
        await waitForBlockedRewrite(~attempts=attempts - 1)
      | _ => JsError.throwWithMessage("The batch was never written again")
      }
    }
    await waitForBlockedRewrite(~attempts=500)
  })
  commitArrives
}

let settleHeldCommitOnceRewriteBlocks = async (
  indexer: IndexerRunner.t,
  ~outage,
  ~releaseHandler,
  ~deliver,
) => {
  let commitArrives = await indexer->holdCommitUntilRewriteBlocks(
    ~outage,
    ~releaseHandler,
    ~deliver,
  )
  commitArrives.release()
  await indexer.waitUntilIdle()
}

describe("Postgres going away mid-run", () => {
  scenario->Scenario.it(
    "loads the entity again once it is back, without stopping",
    ~sources=[{chain: 1337, methods: [#getHeightOrThrow, #getItemsOrThrow]}],
    ~postgresPort=proxyPort,
    async (~t, ~indexer, ~source) => {
      let outage = outageWithDatabaseUp()
      let source = source(1337)
      await Scenario.resolveInitialHeight(~source, ~head=100)
      let (handled, releaseHandler) = makeHeldHandler()
      await source->replyWithOneTally(~handled)
      await indexer.advanceTime(1_000)

      outage.goDown()
      releaseHandler()
      await indexer.advanceTime(0)
      outage.comeBack()
      await indexer.advanceTime(10_000)

      let tallies: array<tally> = await indexer.query("Tally")
      t.expect((
        tallies,
        (await indexer.queryChains())->Array.map(chain => chain.progressBlock),
        indexer->retriedOperations,
      )).toEqual(([{id: "1", count: 1.}], [50], ["Tally.get"]))
    },
  )

  scenario->Scenario.it(
    "writes the batch again once it is back, without stopping",
    ~sources=[{chain: 1337, methods: [#getHeightOrThrow, #getItemsOrThrow]}],
    ~postgresPort=proxyPort,
    async (~t, ~indexer, ~source) => {
      let outage = outageWithDatabaseUp()
      let source = source(1337)
      await Scenario.resolveInitialHeight(~source, ~head=100)
      let (handled, releaseHandler) = makeHeldHandler()
      await source->replyWithOneTally(~handled, ~load=false)
      await indexer.advanceTime(1_000)

      outage.goDown()
      releaseHandler()
      await indexer.advanceTime(0)
      outage.comeBack()
      await indexer.advanceTime(10_000)

      let tallies: array<tally> = await indexer.query("Tally")
      t.expect((
        tallies,
        (await indexer.queryChains())->Array.map(chain => chain.progressBlock),
        indexer->retriedOperations,
      )).toEqual(([{id: "1", count: 1.}], [50], ["batch write"]))
    },
  )

  scenario->Scenario.it(
    "writes the chain metadata again once it is back, without stopping",
    ~sources=[{chain: 1337, methods: [#getHeightOrThrow, #getItemsOrThrow]}],
    ~postgresPort=proxyPort,
    async (~t, ~indexer, ~source) => {
      let outage = outageWithDatabaseUp()
      let source = source(1337)
      await Scenario.resolveInitialHeight(~source, ~head=100)
      let (handled, releaseHandler) = makeHeldHandler()

      // With the handler held, the chain metadata the response staged is
      // written on its own, while nothing answers.
      outage.goDown()
      await source->replyWithOneTally(~handled)
      await indexer.advanceTime(0)
      outage.comeBack()
      await indexer.advanceTime(10_000)
      releaseHandler()
      await indexer.advanceTime(0)

      let tallies: array<tally> = await indexer.query("Tally")
      t.expect((
        tallies,
        (await indexer.queryChains())->Array.map(chain => chain.progressBlock),
        indexer->retriedOperations,
      )).toEqual(([{id: "1", count: 1.}], [50], ["chain metadata write"]))
    },
  )

  // A batch processed behind the one being retried must not land without it:
  // its progress would claim the retried blocks, and a restart would resume
  // past rows that were never written.
  let errors = []
  scenario->Scenario.it(
    "writes nothing behind the retried batch once the indexer stops",
    ~sources=[{chain: 1337, methods: [#getHeightOrThrow, #getItemsOrThrow]}],
    ~postgresPort=proxyPort,
    ~onError=error => errors->Array.push(error.msg)->ignore,
    async (~t, ~indexer, ~source) => {
      let outage = outageWithDatabaseUp()
      let source = source(1337)
      await Scenario.resolveInitialHeight(~source, ~head=100)
      let (handled, releaseHandler) = makeHeldHandler()
      await source->replyWithOneTally(~handled, ~load=false)
      await indexer.advanceTime(1_000)

      outage.goDown()
      releaseHandler()
      await indexer.advanceTime(0)
      await source.expectItemsQueries([
        {
          fromBlock: 51,
          toBlock: Unbounded,
          reply: Respond({
            items: [
              {
                blockNumber: 60,
                logIndex: 0,
                handler: async args => (args->contextOf).tally.set({id: "2", count: 1.}),
              },
            ],
            latestFetchedBlockNumber: 70,
            knownHeight: 100,
          }),
        },
      ])
      await indexer.advanceTime(0)
      await source.expectItemsQueries([
        {
          fromBlock: 71,
          toBlock: Bounded(100),
          reply: Respond({
            items: [
              {
                blockNumber: 80,
                logIndex: 0,
                handler: async _ => JsError.throwWithMessage("handler blew up"),
              },
            ],
            latestFetchedBlockNumber: 90,
            knownHeight: 100,
          }),
        },
      ])
      await indexer.advanceTime(0)
      outage.comeBack()
      await indexer.advanceTime(10_000)

      let tallies: array<tally> = await indexer.query("Tally")
      t.expect((
        tallies,
        (await indexer.queryChains())->Array.map(chain => chain.progressBlock),
        errors,
      )).toEqual((
        [],
        [-1],
        [
          Some(
            "Unexpected error in the event handler. Please handle the error to keep the indexer running smoothly.",
          ),
        ],
      ))
    },
  )

  let lateErrors = []
  scenario->Scenario.it(
    "carries on when the database answers just before the minute is up",
    ~sources=[{chain: 1337, methods: [#getHeightOrThrow, #getItemsOrThrow]}],
    ~postgresPort=proxyPort,
    ~onError=error => lateErrors->Array.push(error.msg)->ignore,
    async (~t, ~indexer, ~source) => {
      let outage = outageWithDatabaseUp()
      let source = source(1337)
      await Scenario.resolveInitialHeight(~source, ~head=100)
      let (handled, releaseHandler) = makeHeldHandler()
      await source->replyWithOneTally(~handled, ~load=false)
      await indexer.advanceTime(1_000)

      outage.goDown()
      releaseHandler()
      await indexer.advanceTime(0)
      await indexer.advanceTime(58_000)
      outage.comeBack()
      // The last attempt is made at the minute, so it finds the database.
      await indexer.advanceTime(2_000)

      let tallies: array<tally> = await indexer.query("Tally")
      t.expect((
        tallies,
        (await indexer.queryChains())->Array.map(chain => chain.progressBlock),
        lateErrors,
      )).toEqual(([{id: "1", count: 1.}], [50], []))
    },
  )

  let repeatedErrors = []
  scenario->Scenario.it(
    "gives every outage its own minute",
    ~sources=[{chain: 1337, methods: [#getHeightOrThrow, #getItemsOrThrow]}],
    ~postgresPort=proxyPort,
    ~onError=error => repeatedErrors->Array.push(error.msg)->ignore,
    async (~t, ~indexer, ~source) => {
      let outage = outageWithDatabaseUp()
      let source = source(1337)
      await Scenario.resolveInitialHeight(~source, ~head=100)
      let (handled, releaseHandler) = makeHeldHandler()
      await source->replyWithOneTally(~handled, ~load=false)
      await indexer.advanceTime(1_000)

      // Two 40-second outages, 80 seconds of waiting in all.
      outage.goDown()
      releaseHandler()
      await indexer.advanceTime(0)
      await indexer.advanceTime(40_000)
      outage.comeBack()
      await indexer.advanceTime(5_000)

      outage.goDown()
      await source.expectItemsQueries([
        {
          fromBlock: 51,
          toBlock: Unbounded,
          reply: Respond({
            items: [
              {
                blockNumber: 60,
                logIndex: 0,
                handler: async args => (args->contextOf).tally.set({id: "2", count: 1.}),
              },
            ],
            latestFetchedBlockNumber: 70,
            knownHeight: 100,
          }),
        },
      ])
      await indexer.advanceTime(0)
      await indexer.advanceTime(40_000)
      outage.comeBack()
      await indexer.advanceTime(5_000)

      let tallies: array<tally> = await indexer.query("Tally")
      t.expect((
        tallies->Array.toSorted((a, b) => String.compare(a.id, b.id)),
        (await indexer.queryChains())->Array.map(chain => chain.progressBlock),
        repeatedErrors,
      )).toEqual(([{id: "1", count: 1.}, {id: "2", count: 1.}], [70], []))
    },
  )

  // The handler waiting on the load fails with it, and that failure must not
  // read as the handler's own on top of the one that says what happened.
  let loadDeadlineErrors = []
  scenario->Scenario.it(
    "stops a waiting load with the same single error at the minute",
    ~sources=[{chain: 1337, methods: [#getHeightOrThrow, #getItemsOrThrow]}],
    ~postgresPort=proxyPort,
    ~onError=error => loadDeadlineErrors->Array.push(error.msg)->ignore,
    async (~t, ~indexer, ~source) => {
      let outage = outageWithDatabaseUp()
      let source = source(1337)
      await Scenario.resolveInitialHeight(~source, ~head=100)
      let (handled, releaseHandler) = makeHeldHandler()
      await source->replyWithOneTally(~handled)
      await indexer.advanceTime(1_000)

      outage.goDown()
      releaseHandler()
      await indexer.advanceTime(0)
      await indexer.advanceTime(60_000)
      outage.comeBack()
      await indexer.advanceTime(10_000)

      let tallies: array<tally> = await indexer.query("Tally")
      t.expect((loadDeadlineErrors, indexer->retriedOperations, tallies)).toEqual((
        [Some(ConnectionRetry.unreachableMsg)],
        ["Tally.get"],
        [],
      ))
    },
  )

  let deadlineErrors = []
  scenario->Scenario.it(
    "stops with an error once the database stays away for a minute",
    ~sources=[{chain: 1337, methods: [#getHeightOrThrow, #getItemsOrThrow]}],
    ~postgresPort=proxyPort,
    ~onError=error => deadlineErrors->Array.push(error.msg)->ignore,
    async (~t, ~indexer, ~source) => {
      let outage = outageWithDatabaseUp()
      let source = source(1337)
      await Scenario.resolveInitialHeight(~source, ~head=100)
      let (handled, releaseHandler) = makeHeldHandler()
      await source->replyWithOneTally(~handled, ~load=false)
      await indexer.advanceTime(1_000)

      outage.goDown()
      releaseHandler()
      await indexer.advanceTime(0)
      await indexer.advanceTime(59_000)
      let errorsBeforeTheMinute = deadlineErrors->Array.length
      await indexer.advanceTime(1_000)
      outage.comeBack()
      // Nothing is sent again after giving up, however long the run goes on.
      await indexer.advanceTime(10_000)

      let tallies: array<tally> = await indexer.query("Tally")
      t.expect((errorsBeforeTheMinute, deadlineErrors, tallies)).toEqual((
        0,
        [
          Some(
            "The database has been unreachable for 60 seconds. The \"Lost the connection to the database\" warnings above show the error behind it. Check that Postgres is running and that ENVIO_PG_HOST and ENVIO_PG_PORT point at it. Once the issue is resolved and the indexer is restarted, it resumes from the last block it saved.",
          ),
        ],
        [],
      ))
    },
  )

  // The COMMIT the connection was carrying when it went may or may not have
  // reached the server, so the batch is looked for before it is written
  // again: written twice, it would store its history and checkpoints twice.
  [(true, "committed"), (false, "rolled back")]->Array.forEach(((deliver, outcome)) => {
    let commitErrors = []
    scenario->Scenario.it(
      `finds out whether a batch whose COMMIT was cut off ${outcome}`,
      ~sources=[{chain: 1337, methods: [#getHeightOrThrow, #getItemsOrThrow]}],
      ~postgresPort=proxyPort,
      ~onError=error => commitErrors->Array.push(error.msg)->ignore,
      async (~t, ~indexer, ~source) => {
        let outage = outageWithDatabaseUp()
        let source = source(1337)
        await Scenario.resolveInitialHeight(~source, ~head=100)
        let (handled, releaseHandler) = makeHeldHandler()
        await source->replyWithOneTally(~handled, ~load=false)
        await indexer.advanceTime(1_000)

        outage.cutNextCommit(~deliver)
        releaseHandler()
        await indexer.advanceTime(0)
        await indexer.advanceTime(5_000)

        let tallies: array<tally> = await indexer.query("Tally")
        t.expect((
          tallies,
          (await indexer.queryChains())->Array.map(chain => chain.progressBlock),
          (await indexer.queryCheckpoints())->Array.map(({blockNumber}) => blockNumber),
          indexer->retriedOperations,
          commitErrors,
        )).toEqual(([{id: "1", count: 1.}], [50], [1, 50], ["batch write"], []))
      },
    )
  })

  // The batch is looked for before its COMMIT reaches the server, so it reads
  // as unwritten and goes out again. Writing it again waits on the held
  // transaction's rows and collides with it on the checkpoint key once that
  // commits, after which the batch is found.
  let lateCommitErrors = []
  scenario->Scenario.it(
    "finds a batch landed when its cut-off COMMIT reaches the server after the batch is looked for",
    ~sources=[{chain: 1337, methods: [#getHeightOrThrow, #getItemsOrThrow]}],
    ~postgresPort=proxyPort,
    ~onError=error => lateCommitErrors->Array.push(error.msg)->ignore,
    async (~t, ~indexer, ~source) => {
      let outage = outageWithDatabaseUp()
      let source = source(1337)
      await Scenario.resolveInitialHeight(~source, ~head=100)
      let (handled, releaseHandler) = makeHeldHandler()
      await source->replyWithOneTally(~handled, ~load=false)
      await indexer.advanceTime(1_000)

      await indexer->settleHeldCommitOnceRewriteBlocks(~outage, ~releaseHandler, ~deliver=true)

      let tallies: array<tally> = await indexer.query("Tally")
      t.expect((
        tallies,
        (await indexer.queryChains())->Array.map(chain => chain.progressBlock),
        (await indexer.queryCheckpoints())->Array.map(({blockNumber}) => blockNumber),
        lateCommitErrors,
      )).toEqual(([{id: "1", count: 1.}], [50], [1, 50], []))
    },
  )

  // The rewrite waits on the same rows, but the server rolls the held
  // transaction back, so the rewrite is the one that stores the batch.
  let droppedCommitErrors = []
  scenario->Scenario.it(
    "stores a batch once when its held COMMIT never reaches the server while the batch is written again",
    ~sources=[{chain: 1337, methods: [#getHeightOrThrow, #getItemsOrThrow]}],
    ~postgresPort=proxyPort,
    ~onError=error => droppedCommitErrors->Array.push(error.msg)->ignore,
    async (~t, ~indexer, ~source) => {
      let outage = outageWithDatabaseUp()
      let source = source(1337)
      await Scenario.resolveInitialHeight(~source, ~head=100)
      let (handled, releaseHandler) = makeHeldHandler()
      await source->replyWithOneTally(~handled, ~load=false)
      await indexer.advanceTime(1_000)

      await indexer->settleHeldCommitOnceRewriteBlocks(~outage, ~releaseHandler, ~deliver=false)

      let tallies: array<tally> = await indexer.query("Tally")
      t.expect((
        tallies,
        (await indexer.queryChains())->Array.map(chain => chain.progressBlock),
        (await indexer.queryCheckpoints())->Array.map(({blockNumber}) => blockNumber),
        indexer->retriedOperations,
        droppedCommitErrors,
      )).toEqual(([{id: "1", count: 1.}], [50], [1, 50], ["batch write"], []))
    },
  )

  // The rewrite fails on its own, for a reason other than a lost connection,
  // while the held COMMIT still hasn't reached the server. That failure says
  // nothing about the batch, so the batch is looked for. It isn't there, so the
  // run stops rather than take the batch as saved.
  let failedRewriteErrors = []
  scenario->Scenario.it(
    "stops when a rewrite fails while its batch, whose COMMIT was cut off, is not there",
    ~sources=[{chain: 1337, methods: [#getHeightOrThrow, #getItemsOrThrow]}],
    ~postgresPort=proxyPort,
    ~onError=error => failedRewriteErrors->Array.push(error.msg)->ignore,
    async (~t, ~indexer, ~source) => {
      let outage = outageWithDatabaseUp()
      let source = source(1337)
      await Scenario.resolveInitialHeight(~source, ~head=100)
      let (handled, releaseHandler) = makeHeldHandler()
      await source->replyWithOneTally(~handled, ~load=false)
      await indexer.advanceTime(1_000)

      let commitArrives = await indexer->holdCommitUntilRewriteBlocks(
        ~outage,
        ~releaseHandler,
        ~deliver=false,
      )
      let cancelled = []
      await indexer.usePostgresSql(async sql => {
        (
          await sql->StorageClient.queryForTests(
            `SELECT pg_cancel_backend(pid) AS cancelled ${indexer->lockWaitersOf}`,
          )
        )->Array.forEach(
          row =>
            cancelled->Array.push(row->Dict.getUnsafe("cancelled")->(Utils.magic: unknown => bool)),
        )
        let rec waitForStop = async (~attempts) =>
          if failedRewriteErrors->Utils.Array.isEmpty && attempts > 0 {
            // Real time: the batch is looked for over the network, off the
            // indexer's clock.
            await Utils.delay(10)
            await waitForStop(~attempts=attempts - 1)
          }
        await waitForStop(~attempts=200)
      })
      commitArrives.release()

      let tallies: array<tally> = await indexer.query("Tally")
      t.expect((
        cancelled,
        tallies,
        (await indexer.queryCheckpoints())->Array.map(({blockNumber}) => blockNumber),
        failedRewriteErrors,
      )).toEqual(([true], [], [], [Some("Failed writing batch to the database")]))
    },
  )

  let afterLateCommitErrors = []
  scenario->Scenario.it(
    "builds the next batch on a batch found landed behind its late COMMIT",
    ~sources=[{chain: 1337, methods: [#getHeightOrThrow, #getItemsOrThrow]}],
    ~postgresPort=proxyPort,
    ~onError=error => afterLateCommitErrors->Array.push(error.msg)->ignore,
    async (~t, ~indexer, ~source) => {
      let outage = outageWithDatabaseUp()
      let source = source(1337)
      await Scenario.resolveInitialHeight(~source, ~head=100)
      let (handled, releaseHandler) = makeHeldHandler()
      await source->replyWithOneTally(~handled, ~load=false)
      await indexer.advanceTime(1_000)

      await indexer->settleHeldCommitOnceRewriteBlocks(~outage, ~releaseHandler, ~deliver=true)
      await source.expectItemsQueries([
        {
          fromBlock: 51,
          toBlock: Unbounded,
          reply: Respond({
            items: [
              {
                blockNumber: 60,
                logIndex: 0,
                handler: async args => {
                  let tally = (args->contextOf).tally
                  let count = (await tally.get("1"))->Option.mapOr(0., tally => tally.count)
                  tally.set({id: "1", count: count +. 1.})
                },
              },
            ],
            latestFetchedBlockNumber: 70,
            knownHeight: 100,
          }),
        },
      ])
      await indexer.advanceTime(1_000)

      let tallies: array<tally> = await indexer.query("Tally")
      t.expect((
        tallies,
        (await indexer.queryChains())->Array.map(chain => chain.progressBlock),
        (await indexer.queryCheckpoints())->Array.map(({blockNumber}) => blockNumber),
        afterLateCommitErrors,
      )).toEqual(([{id: "1", count: 2.}], [70], [1, 50, 60, 70], []))
    },
  )
})
