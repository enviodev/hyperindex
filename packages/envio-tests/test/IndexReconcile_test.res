open Vitest

let configYaml = `
name: index-reconcile
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
`

let scenario = Scenario.make(
  ~supervised=false,
  ~configYaml,
  ~schema=`
type A {
  id: ID!
  b: B! @index
}

type B {
  id: ID!
  a: [A!]! @derivedFrom(field: "b")
}
`,
)

// Entity names are capped at 63 characters by codegen, so nothing the indexer
// creates should ever be truncated by Postgres.
let longName = `Entity${"x"->String.repeat(57)}`
let longNameScenario = Scenario.make(
  ~supervised=false,
  ~configYaml,
  ~schema=`
type ${longName} {
  id: ID!
  owner: String! @index
}
`,
)

let tripleScenario = Scenario.make(
  ~supervised=false,
  ~configYaml,
  ~schema=`
type Triple {
  id: ID!
  first: String! @index
  second: String! @index
  third: String! @index
}
`,
)

let aBIdName = "A_b_id_556h9mdu8a"

let indexesOn = async (indexer: IndexerRunner.t, ~tableName) => {
  let {sql, pgSchema} = indexer.pg
  (await sql->PgCatalog.indexes(~pgSchema))->Array.filter(index =>
    index.tableName === tableName && !index.isUnique
  )
}

// What the storage told the operator about its indexes, with build timings
// left out.
let storageMessages = (indexer: IndexerRunner.t) =>
  indexer.logs()
  ->Array.filter(entry => entry.params->Dict.get("storage") === Some(JSON.String("postgres")))
  ->Array.map(entry => entry.msg->String.replaceRegExp(/[0-9.]+s\b/g, "Ns"))

let describeIndex = (index: PgCatalog.index) => (
  index.name,
  index.columns,
  index.isValid,
  index.isPartial,
)

let restartToReady = async (indexer: IndexerRunner.t, ~source: MockSource.t) => {
  source.setAutoHeight(100)
  let restarted = await indexer.restart()
  source.resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=100)
  await restarted.waitUntilReady()
  restarted
}

let shape = async (indexer: IndexerRunner.t, statement) => {
  let {sql, pgSchema} = indexer.pg
  let _ = await sql->Sql.query(statement(pgSchema))
}

let readyAt = async (indexer: IndexerRunner.t) => {
  let {sql, pgSchema} = indexer.pg
  let rows: array<{
    "ready_at": Null.t<Date.t>,
  }> = await sql->Sql.query(`SELECT "ready_at" FROM "${pgSchema}"."envio_chains";`)
  rows->Array.map(row => row["ready_at"]->Null.toOption->Option.isSome)
}

type a = {id: string, b_id: string}
type aOps = {set: a => unit, getWhere: {"b_id": {"_eq": string}} => promise<array<a>>}
type handlerContext = {@as("A") a: aOps}

describe("Indexes on a database that already holds some", () => {
  // A WHERE clause covers only the rows inside its predicate, so it can't
  // answer the unrestricted lookups a filter makes.
  scenario->Scenario.it("build a full index beside a partial one", ~sources=[{chain: 1337}], async (
    ~t,
    ~indexer,
    ~source,
  ) => {
    await indexer->shape(
      pgSchema => `CREATE INDEX "A_b_id" ON "${pgSchema}"."A"("b_id") WHERE "b_id" IS NOT NULL;`,
    )
    let restarted = await indexer->restartToReady(~source=source(1337))

    t.expect((await restarted->indexesOn(~tableName="A"))->Array.map(describeIndex)).toEqual([
      ("A_b_id", ["b_id"], true, true),
      (aBIdName, ["b_id"], true, false),
    ])
  })

  // Same identity under an older name: matching on what an index covers keeps
  // it instead of building a duplicate.
  scenario->Scenario.it(
    "keep a usable index the indexer didn't name",
    ~sources=[{chain: 1337}],
    async (~t, ~indexer, ~source) => {
      await indexer->shape(pgSchema => `CREATE INDEX "A_b_id" ON "${pgSchema}"."A"("b_id");`)
      let restarted = await indexer->restartToReady(~source=source(1337))

      t.expect((await restarted->indexesOn(~tableName="A"))->Array.map(describeIndex)).toEqual([
        ("A_b_id", ["b_id"], true, false),
      ])
    },
  )

  // A `CREATE UNIQUE INDEX CONCURRENTLY` that fails on duplicate data leaves an
  // invalid index holding its name. The planner can't use it, so it must never
  // count as coverage.
  scenario->Scenario.it(
    "build a usable index beside one a failed build left invalid",
    ~sources=[{chain: 1337}],
    async (~t, ~indexer, ~source) => {
      await indexer->shape(
        pgSchema =>
          `INSERT INTO "${pgSchema}"."A" ("id", "b_id") VALUES ('1', 'dup'), ('2', 'dup');`,
      )
      let {sql, pgSchema} = indexer.pg
      let failed = switch await sql->Sql.query(
        `CREATE UNIQUE INDEX CONCURRENTLY "A_b_id" ON "${pgSchema}"."A"("b_id");`,
      ) {
      | _ => false
      | exception _ => true
      }
      let _ = await indexer->restartToReady(~source=source(1337))

      t.expect((
        failed,
        (await sql->PgCatalog.indexes(~pgSchema))
        ->Array.filter(index => index.tableName === "A" && index.columns == ["b_id"])
        ->Array.map(index => (index.name, index.isValid)),
      )).toEqual((true, [("A_b_id", false), (aBIdName, true)]))
    },
  )

  // A second finalization has to recognise what the first one built. Had the
  // stored name and the one matched on drifted, it would build another.
  longNameScenario->Scenario.it(
    "recognise what they built on a table at the identifier limit",
    ~sources=[{chain: 1337}],
    ~captureLogs=true,
    async (~t, ~indexer, ~source) => {
      let source = source(1337)
      source.resolveGetHeightOrThrow(100)
      source.resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=100)
      await indexer.waitUntilReady()
      let built = await indexer->indexesOn(~tableName=longName)

      // Unstamped, the restart finalizes again rather than resuming ready.
      // Stopped first: its last flush carries the stamp it already holds.
      await indexer.stop()
      await indexer->shape(pgSchema => `UPDATE "${pgSchema}"."envio_chains" SET "ready_at" = NULL;`)
      source.setAutoHeight(100)
      let restarted = await indexer.restart()
      await restarted.waitUntilReady()

      t.expect((
        built->Array.map(index => (index.columns, index.isValid)),
        (await restarted->indexesOn(~tableName=longName))->Array.map(index => index.name),
        restarted->storageMessages,
      )).toEqual((
        [(["owner"], true)],
        built->Array.map(index => index.name),
        [
          `Creating the 1 remaining schema indexes before the indexer reports ready. Writes are paused until they are committed. This can take a long time on a large database.`,
          `Committed 1 schema indexes and the ready timestamp in Ns.`,
          `All 1 schema indexes are already in place. Marking the indexer ready.`,
        ],
      ))
    },
  )

  // A getWhere on the column the schema indexes builds that index before the
  // indexer is ready; finalizing then has nothing left to build for it.
  scenario->Scenario.it(
    "reuse the index a getWhere already built for a declared one",
    ~sources=[{chain: 1337}],
    ~captureLogs=true,
    async (~t, ~indexer, ~source) => {
      let source = source(1337)
      source.resolveGetHeightOrThrow(100)
      source.resolveGetItemsOrThrow(
        [
          {
            blockNumber: 10,
            logIndex: 0,
            handler: async args => {
              let context = args.context->(Utils.magic: Internal.handlerContext => handlerContext)
              let _ = await context.a.getWhere({"b_id": {"_eq": "b"}})
              context.a.set({id: "1", b_id: "b"})
            },
          },
        ],
        ~latestFetchedBlockNumber=10,
      )
      await indexer.getBatchWritePromise()
      let beforeReady = await indexer->indexesOn(~tableName="A")
      await MockSource.waitItemsQuery(source)
      source.resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=100)
      await indexer.waitUntilReady()

      // The name is the same either way, so the logs are what tell a reuse from
      // a create that lost to the index already there.
      t.expect((
        beforeReady->Array.map(index => index.name),
        (await indexer->indexesOn(~tableName="A"))->Array.map(index => index.name),
        indexer->storageMessages,
      )).toEqual((
        [aBIdName],
        [aBIdName],
        [
          `Creating index "${aBIdName}" to serve a getWhere query on "A". Writes to the table are paused until it completes. This can take a long time on a large database.`,
          `Index "${aBIdName}" is ready after Ns. Resuming indexing.`,
          `All 1 schema indexes are already in place. Marking the indexer ready.`,
        ],
      ))
    },
  )

  // A btree refuses a key past a third of a page, so one oversized value fails
  // the second build for real. What was built before it stays, nothing is
  // marked ready, and the next start owes only the rest.
  let failure = ref(None)
  tripleScenario->Scenario.it(
    "keep what they built when a later one fails, and finish on the next start",
    ~sources=[{chain: 1337}],
    ~onError=errHandler => failure := Some(errHandler),
    async (~t, ~indexer, ~source) => {
      let source = source(1337)
      await indexer->shape(pgSchema =>
        `INSERT INTO "${pgSchema}"."Triple" ("id", "first", "second", "third")
           SELECT '1', 'a', string_agg(md5(i::text), ''), 'c' FROM generate_series(1, 1000) i;`
      )
      source.setAutoHeight(100)
      let restarted = await indexer.restart()
      source.resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=100)
      await Scenario.waitUntil(
        () => failure.contents->Option.isSome,
        ~message="the second index build to fail",
      )
      let afterFailure = (
        (await restarted->indexesOn(~tableName="Triple"))->Array.map(index => index.columns),
        await restarted->readyAt,
      )

      await restarted->shape(pgSchema => `UPDATE "${pgSchema}"."Triple" SET "second" = 'b';`)
      // Progress already sits at the head, so the restart has nothing left to
      // fetch and goes straight back to building.
      let finished = await restarted.restart()
      await finished.waitUntilReady()

      t.expect((
        afterFailure,
        (
          (await finished->indexesOn(~tableName="Triple"))->Array.map(index => index.columns),
          await finished->readyAt,
        ),
      )).toEqual((([["first"]], [false]), ([["first"], ["second"], ["third"]], [true])))
    },
  )
})
