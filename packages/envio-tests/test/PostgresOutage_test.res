open Vitest

// A database restart, a failover or a pooler in front of either drops the
// indexer's connections mid-run. What is safe to send again — a load, the
// chain metadata upsert, a batch that never reached COMMIT — is sent again once
// the database answers, for up to a minute, rather than ending the run.
let proxyPort = 18563

let outageRef = ref(None)
Async.beforeAll(async () => {
  outageRef := Some(await PostgresOutage.start(~port=proxyPort, ~upstreamPort=Env.Db.port))
})
Async.afterAll(async () =>
  switch outageRef.contents {
  | Some(outage) => await outage.close()
  | None => ()
  }
)

// Up at the start of every test, whatever the one before it left behind.
let takeOutage = () => {
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

// The proxy refusing a connection is real socket I/O. `advanceTime(0)` right
// after `goDown` waits on it the way it waits on any write in flight, so the
// attempt has failed, and armed its retry, before the database comes back.
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

describe("Postgres going away mid-run", () => {
  scenario->Scenario.it(
    "loads the entity again once it is back, without stopping",
    ~sources=[{chain: 1337, methods: [#getHeightOrThrow, #getItemsOrThrow]}],
    ~postgresPort=proxyPort,
    async (~t, ~indexer, ~source) => {
      let outage = takeOutage()
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
      let outage = takeOutage()
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
      let outage = takeOutage()
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
      let outage = takeOutage()
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

  let deadlineErrors = []
  scenario->Scenario.it(
    "stops with an error once the database stays away for a minute",
    ~sources=[{chain: 1337, methods: [#getHeightOrThrow, #getItemsOrThrow]}],
    ~postgresPort=proxyPort,
    ~onError=error => deadlineErrors->Array.push(error.msg)->ignore,
    async (~t, ~indexer, ~source) => {
      let outage = takeOutage()
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
            "The database has been unreachable for 60 seconds, so the indexer is stopping. The \"Lost the connection to the database\" warnings above show the error behind it. Check that Postgres is running and that ENVIO_PG_HOST and ENVIO_PG_PORT point at it, then start the indexer again: it resumes from the last batch it saved.",
          ),
        ],
        [],
      ))
    },
  )
})
