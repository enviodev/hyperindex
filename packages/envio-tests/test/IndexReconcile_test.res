open Vitest

// What a database already holds when the indexer starts on it decides what it
// builds: an index it can use is kept, one it can't is built beside, and a
// build that fails leaves the ones before it standing. Every case starts the
// indexer once to create the tables, shapes the indexes by hand, then restarts
// it the way an operator would and lets it catch up.

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

let describeIndex = (index: PgCatalog.index) => (
  index.name,
  index.columns,
  index.isValid,
  index.isPartial,
)

// Restarts onto the shaped schema and lets the indexer catch up to the head.
let restartToReady = async (indexer: IndexerRunner.t, ~source: MockSource.t) => {
  source.setAutoHeight(100)
  let restarted = await indexer.restart()
  source.resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=100)
  await restarted.waitUntilReady()
  restarted
}

let shape = async (indexer: IndexerRunner.t, statements) => {
  let {sql, pgSchema} = indexer.pg
  for idx in 0 to statements->Array.length - 1 {
    let statement = statements->Array.getUnsafe(idx)
    let _ = await sql->Sql.query(statement(pgSchema))
  }
}

describe("Indexes on a database that already holds some", () => {
  // A WHERE clause covers only the rows inside its predicate, so it can't
  // answer the unrestricted lookups a filter makes.
  scenario->Scenario.it("build a full index beside a partial one", ~sources=[{chain: 1337}], async (
    ~t,
    ~indexer,
    ~source,
  ) => {
    await indexer->shape([
      pgSchema => `CREATE INDEX "A_b_id" ON "${pgSchema}"."A"("b_id") WHERE "b_id" IS NOT NULL;`,
    ])
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
      await indexer->shape([pgSchema => `CREATE INDEX "A_b_id" ON "${pgSchema}"."A"("b_id");`])
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
      await indexer->shape([
        pgSchema =>
          `INSERT INTO "${pgSchema}"."A" ("id", "b_id") VALUES ('1', 'dup'), ('2', 'dup');`,
      ])
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

  // A second start has to recognise what the first one built. Had the stored
  // name and the one matched on drifted, it would build another.
  longNameScenario->Scenario.it(
    "recognise what they built on a table at the identifier limit",
    ~sources=[{chain: 1337}],
    async (~t, ~indexer, ~source) => {
      let source = source(1337)
      source.resolveGetHeightOrThrow(100)
      source.resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=100)
      await indexer.waitUntilReady()
      let built = await indexer->indexesOn(~tableName=longName)

      source.setAutoHeight(100)
      let restarted = await indexer.restart()
      await restarted.waitUntilIdle()

      t.expect((
        longName->String.length,
        built->Array.map(index => (index.columns, index.isValid)),
        (await restarted->indexesOn(~tableName=longName))->Array.map(index => index.name),
      )).toEqual((63, [(["owner"], true)], built->Array.map(index => index.name)))
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
      await indexer->shape([
        pgSchema =>
          `INSERT INTO "${pgSchema}"."Triple" ("id", "first", "second", "third")
           SELECT '1', 'a', string_agg(md5(i::text), ''), 'c' FROM generate_series(1, 1000) i;`,
      ])
      source.setAutoHeight(100)
      let restarted = await indexer.restart()
      source.resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=100)
      await Scenario.waitUntil(
        () => failure.contents->Option.isSome,
        ~message="the second index build to fail",
      )
      let afterFailure = (
        (await restarted->indexesOn(~tableName="Triple"))->Array.map(index => index.columns),
        await restarted.metric("envio_progress_ready"),
      )

      await restarted->shape([pgSchema => `UPDATE "${pgSchema}"."Triple" SET "second" = 'b';`])
      // Progress already sits at the head, so the restart has nothing left to
      // fetch and goes straight back to building.
      let finished = await restarted.restart()
      await finished.waitUntilReady()

      t.expect((
        afterFailure,
        (await finished->indexesOn(~tableName="Triple"))->Array.map(index => index.columns),
      )).toEqual((
        ([["first"]], [{IndexerRunner.value: "0", labels: dict{"chainId": "1337"}}]),
        [["first"], ["second"], ["third"]],
      ))
    },
  )
})
