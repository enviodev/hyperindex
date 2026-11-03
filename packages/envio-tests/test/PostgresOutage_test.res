open Vitest

// A database restart, a failover or a pooler in front of either drops the
// indexer's connections mid-write. A batch that never reached COMMIT is
// written again once the database answers, rather than ending the run.
let proxyPort = 18563

let outage = ref(None)
Async.beforeAll(async () => {
  outage := Some(await PostgresOutage.start(~port=proxyPort, ~upstreamPort=Env.Db.port))
})
Async.afterAll(async () =>
  switch outage.contents {
  | Some(outage) => await outage.close()
  | None => ()
  }
)

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
type tallyOps = {set: tally => unit}
type handlerContext = {@as("Tally") tally: tallyOps}

let contextOf = (args: Internal.handlerArgs) =>
  args.context->(Utils.magic: Internal.handlerContext => handlerContext)

let replyWithOneTally = async (source: MockSource.t, ~handled=Promise.resolve()) =>
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
              (args->contextOf).tally.set({id: "1", count: 1.})
            },
          },
        ],
        latestFetchedBlockNumber: 50,
        knownHeight: 100,
      }),
    },
  ])

// What each write sent again was doing when the connection went.
let retriedWrites = (indexer: IndexerRunner.t) =>
  indexer.infoAndAboveLogs()->Array.filterMap(({msg, params}) =>
    msg == "Lost the database connection before the write committed. Writing it again"
      ? switch params->Dict.get("err") {
        | Some(String(err)) => err->String.split(": ")->Array.get(0)
        | _ => None
        }
      : None
  )

describe("Postgres going away mid-run", () => {
  scenario->Scenario.it(
    "writes the batch again once it is back, without stopping",
    ~sources=[{chain: 1337, methods: [#getHeightOrThrow, #getItemsOrThrow]}],
    ~postgresPort=proxyPort,
    async (~t, ~indexer, ~source) => {
      let outage = outage.contents->Option.getOrThrow
      let source = source(1337)
      await Scenario.resolveInitialHeight(~source, ~head=100)
      // The handler is held while the chain metadata the response staged
      // lands, so the batch is the write the outage cuts off.
      let releaseHandler = ref(ignore)
      let handled = Promise.make((resolve, _) => releaseHandler := resolve)
      await source->replyWithOneTally(~handled)
      await indexer.advanceTime(1_000)

      outage.goDown()
      releaseHandler.contents()
      await indexer.advanceTime(0)
      outage.comeBack()
      await indexer.advanceTime(10_000)

      let tallies: array<tally> = await indexer.query("Tally")
      t.expect((
        tallies,
        (await indexer.queryChains())->Array.map(chain => chain.progressBlock),
        indexer->retriedWrites->Set.fromArray->Set.values->Array.fromIterator,
      )).toEqual(([{id: "1", count: 1.}], [50], ["Failed opening the batch's transaction"]))
    },
  )

  scenario->Scenario.it(
    "writes the chain metadata again once it is back, without stopping",
    ~sources=[{chain: 1337, methods: [#getHeightOrThrow, #getItemsOrThrow]}],
    ~postgresPort=proxyPort,
    async (~t, ~indexer, ~source) => {
      let outage = outage.contents->Option.getOrThrow
      let source = source(1337)
      await Scenario.resolveInitialHeight(~source, ~head=100)
      // The handler is held, so the chain metadata the response staged is
      // written on its own, while nothing answers.
      let releaseHandler = ref(ignore)
      let handled = Promise.make((resolve, _) => releaseHandler := resolve)

      outage.goDown()
      await source->replyWithOneTally(~handled)
      await indexer.advanceTime(0)
      outage.comeBack()
      await indexer.advanceTime(10_000)
      releaseHandler.contents()
      await indexer.advanceTime(0)

      let tallies: array<tally> = await indexer.query("Tally")
      let retried = indexer->retriedWrites
      t.expect((
        tallies,
        (await indexer.queryChains())->Array.map(chain => chain.progressBlock),
        retried->Array.length > 0 &&
          !(retried->Array.includes("Failed opening the batch's transaction")),
      )).toEqual(([{id: "1", count: 1.}], [50], true))
    },
  )
})
