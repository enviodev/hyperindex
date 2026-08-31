open Vitest

let schema = `
type A {
  id: ID!
  b: B! @index
  optionalStringToTestLinkedEntities: String
}

type B {
  id: ID!
  a: [A!]! @derivedFrom(field: "b")
  c: C
}

type C {
  id: ID!
  a: A!
  stringThatIsMirroredToA: String!
}
`

let chainYaml = (chainId, address) => `
  - id: ${chainId->Int.toString}
    rpc:
      url: https://rpc${chainId->Int.toString}.example.test
      for: sync
    start_block: 1
    contracts:
      - name: Gravatar
        address: "${address}"
`

let contractsYaml = `
contracts:
  - name: Gravatar
    events:
      - event: "TestEvent()"
`

let scenario = Scenario.make(
  ~configYaml=`
name: schema-indexes${contractsYaml}chains:${chainYaml(
      1337,
      "0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3",
    )}`,
  ~schema,
)

let multichainScenario = Scenario.make(
  ~configYaml=`
name: schema-indexes-multichain${contractsYaml}chains:${chainYaml(
      100,
      "0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3",
    )}${chainYaml(1337, "0x3B2f78c5BF6D9C12Ee1225D5F374aa91204580c3")}`,
  ~schema,
)

let loadCatalog = async (~sql, ~pgSchema) => {
  let rows =
    (await sql->Postgres.unsafe(IndexCatalog.makeQuery(~pgSchema)))->S.parseOrThrow(
      IndexCatalog.rowsSchema,
    )
  IndexCatalog.fromRows(~rows)
}

// Every index on `tableName` whose key columns start with `columns`, so an
// assertion can say what the schema holds rather than what SQL was emitted.
let findIndexes = async (~sql, ~tableName, ~columns, ~pgSchema) => {
  let catalog = await loadCatalog(~sql, ~pgSchema)
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

let indexNames = async (~sql, ~pgSchema) => {
  let catalog = await loadCatalog(~sql, ~pgSchema)
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

let readyAtRows = async (~sql, ~pgSchema) => {
  let rows: array<{
    "id": ChainId.t,
    "ready_at": Null.t<Date.t>,
  }> = await sql->Postgres.unsafe(
    `SELECT "id", "ready_at" FROM "${pgSchema}"."envio_chains" ORDER BY "id";`,
  )
  rows
}

let readyAtByChainId = async (~sql, ~pgSchema) =>
  (await readyAtRows(~sql, ~pgSchema))->Array.map(row => (
    row["id"],
    row["ready_at"]->Null.toOption->Option.isSome,
  ))

// Timestamps rather than flags, for the chains that have to share one.
let readyAtTimesByChainId = async (~sql, ~pgSchema) =>
  (await readyAtRows(~sql, ~pgSchema))->Array.map(row => (
    row["id"],
    row["ready_at"]->Null.toOption->Option.map(Date.toISOString),
  ))

type a = {
  id: string,
  b_id: string,
  optionalStringToTestLinkedEntities: option<string>,
}
type aFilter = {optionalStringToTestLinkedEntities?: Envio.whereOperator<option<string>>}
type aOps = {
  set: a => unit,
  getWhere: aFilter => promise<array<a>>,
}
type indexesContext = {@as("A") a: aOps}

let asContext = (context: Internal.handlerContext) =>
  context->(Utils.magic: Internal.handlerContext => indexesContext)

describe("Deferred schema indexes", () => {
  scenario->Scenario.it(
    "Are absent through backfill, committed with ready_at, and kept across a restart",
    ~sources=[{chain: 1337}],
    async (~t, ~indexer, ~source) => {
      let source = source(1337)
      let {sql, pgSchema} = indexer.pg
      await Utils.delay(0)

      t.expect(
        (
          await findIndexes(~sql, ~tableName="A", ~columns=["b_id"], ~pgSchema),
          await readyAtByChainId(~sql, ~pgSchema),
          await indexer.metric("envio_progress_ready"),
        ),
        ~message="Backfill runs without the schema's read indexes, and nothing is ready",
      ).toEqual((
        [],
        [(ChainId.fromInt(1337), false)],
        [{value: "0", labels: dict{"chainId": "1337"}}],
      ))

      source.resolveGetHeightOrThrow(100)
      source.resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=100)
      await indexer.waitUntilReady()

      t.expect(
        (
          (await findIndexes(~sql, ~tableName="A", ~columns=["b_id"], ~pgSchema))->Array.map(
            entry => (entry.name, entry->isValid, entry->isPartial, entry->method),
          ),
          await readyAtByChainId(~sql, ~pgSchema),
          await indexer.metric("envio_progress_ready"),
        ),
        ~message="ready_at is only committed once every schema-defined index exists",
      ).toEqual((
        [(aBIdIndexName, true, false, "btree")],
        [(ChainId.fromInt(1337), true)],
        [{value: "1", labels: dict{"chainId": "1337"}}],
      ))

      let indexesBeforeRestart = await indexNames(~sql, ~pgSchema)
      let restarted = await indexer.restart()
      await restarted.waitUntilIdle()

      t.expect(
        (await indexNames(~sql, ~pgSchema), await readyAtByChainId(~sql, ~pgSchema)),
        ~message="A resume rediscovers the indexes from the catalog — none are dropped or recreated",
      ).toEqual((indexesBeforeRestart, [(ChainId.fromInt(1337), true)]))
    },
  )

  let gate = ref(MockSource.Gate.make())
  scenario->Scenario.it(
    "Hold the indexer short of ready until they are committed",
    ~sources=[{chain: 1337}],
    ~mapStorage=storage => {
      ...storage,
      finalizeBackfill: (~entities, ~chainIds, ~readyAt) =>
        gate.contents.wait()->Promise.then(() =>
          storage.finalizeBackfill(~entities, ~chainIds, ~readyAt)
        ),
    },
    async (~t, ~indexer, ~source) => {
      let gate = gate.contents
      let source = source(1337)
      let {sql, pgSchema} = indexer.pg

      source.resolveGetHeightOrThrow(100)
      source.resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=100)
      while gate.entered.contents === 0 {
        await Utils.delay(0)
      }

      t.expect(
        (
          await findIndexes(~sql, ~tableName="A", ~columns=["b_id"], ~pgSchema),
          await readyAtByChainId(~sql, ~pgSchema),
          await indexer.metric("envio_progress_ready"),
        ),
        ~message="Caught up to the head, but the indexes aren't committed so nothing is ready",
      ).toEqual((
        [],
        [(ChainId.fromInt(1337), false)],
        [{value: "0", labels: dict{"chainId": "1337"}}],
      ))

      gate.release()
      await indexer.waitUntilReady()

      t.expect((
        (await findIndexes(~sql, ~tableName="A", ~columns=["b_id"], ~pgSchema))->Array.map(
          entry => entry.name,
        ),
        await readyAtByChainId(~sql, ~pgSchema),
      )).toEqual(([aBIdIndexName], [(ChainId.fromInt(1337), true)]))
    },
  )

  // Every scheduling path that reaches the FinalizingIndexes phase joins the
  // in-flight run. Without that, a fetch response landing while the indexes are
  // being built starts a second pass over the same schema.
  let joinGate = ref(MockSource.Gate.make())
  let joinFinalizeCalls = ref(0)
  scenario->Scenario.it(
    "Finalize once however many ticks reach the phase",
    ~sources=[{chain: 1337}],
    ~mapStorage=storage => {
      ...storage,
      finalizeBackfill: (~entities, ~chainIds, ~readyAt) => {
        joinFinalizeCalls := joinFinalizeCalls.contents + 1
        joinGate.contents.wait()->Promise.then(() =>
          storage.finalizeBackfill(~entities, ~chainIds, ~readyAt)
        )
      },
    },
    async (~t, ~indexer, ~source) => {
      let gate = joinGate.contents
      let finalizeCalls = joinFinalizeCalls
      let source = source(1337)

      source.resolveGetHeightOrThrow(100)
      source.resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=100)
      while gate.entered.contents === 0 {
        await Utils.delay(0)
      }

      t.expect(
        (finalizeCalls.contents, await indexer.metric("envio_progress_ready")),
        ~message="Finalization is under way and nothing is ready while it is held",
      ).toEqual((1, [{value: "0", labels: dict{"chainId": "1337"}}]))

      // A height update while the build is held: the chain fetches the new range
      // and its response schedules processing again.
      source.resolveGetHeightOrThrow(200)
      await MockSource.waitItemsQuery(source)
      source.resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=200)
      let ticks = ref(0)
      while ticks.contents < 20 {
        ticks := ticks.contents + 1
        await Utils.delay(0)
      }

      t.expect(
        (finalizeCalls.contents, await indexer.metric("envio_progress_ready")),
        ~message="The new tick joins the in-flight finalization instead of starting another",
      ).toEqual((1, [{value: "0", labels: dict{"chainId": "1337"}}]))

      gate.release()
      await indexer.waitUntilReady()

      t.expect(
        (finalizeCalls.contents, await indexer.metric("envio_progress_ready")),
        ~message="Releasing the build is what makes the indexer ready",
      ).toEqual((1, [{value: "1", labels: dict{"chainId": "1337"}}]))
    },
  )

  // Readiness is a whole-indexer transition: one chain reaching its head means
  // nothing while another is still backfilling.
  let multichainFinalizeCalls = ref(0)
  multichainScenario->Scenario.it(
    "Wait for every chain before finalizing, and stamp them together",
    ~sources=[{chain: 100}, {chain: 1337}],
    ~mapStorage=storage => {
      ...storage,
      finalizeBackfill: (~entities, ~chainIds, ~readyAt) => {
        multichainFinalizeCalls := multichainFinalizeCalls.contents + 1
        storage.finalizeBackfill(~entities, ~chainIds, ~readyAt)
      },
    },
    async (~t, ~indexer, ~source) => {
      let finalizeCalls = multichainFinalizeCalls
      let chainA = source(100)
      let chainB = source(1337)
      let {sql, pgSchema} = indexer.pg

      chainA.resolveGetHeightOrThrow(100)
      chainB.resolveGetHeightOrThrow(100)
      await Utils.delay(0)
      await Utils.delay(0)

      await MockSource.waitItemsQuery(chainA)
      chainA.resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=100)
      await indexer.getBatchWritePromise()

      t.expect(
        (finalizeCalls.contents, await readyAtByChainId(~sql, ~pgSchema)),
        ~message="Chain A is at its head, but chain B is still backfilling",
      ).toEqual((0, [(ChainId.fromInt(100), false), (ChainId.fromInt(1337), false)]))

      await MockSource.waitItemsQuery(chainB)
      chainB.resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=100)
      await indexer.waitUntilReady()

      let readyAtTimes = await readyAtTimesByChainId(~sql, ~pgSchema)
      let times = readyAtTimes->Array.map(((_, readyAt)) => readyAt)
      t.expect(
        (
          finalizeCalls.contents,
          readyAtTimes->Array.map(((id, _)) => id),
          times->Array.every(Option.isSome),
          times->Array.get(0) == times->Array.get(1),
          await indexer.metric("envio_progress_ready"),
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
    },
  )

  // The false-ready bug: `A_b_id` was the name the indexer picked for
  // `A(b_id)`, so an unrelated index holding it on another table turned
  // `CREATE INDEX IF NOT EXISTS` into a no-op and the indexer reported ready
  // with `A(b_id)` unindexed.
  scenario->Scenario.it(
    "Reach ready even when another table holds the legacy index name",
    ~sources=[{chain: 1337}],
    async (~t, ~indexer, ~source) => {
      let source = source(1337)
      let {sql, pgSchema} = indexer.pg
      // The height is unresolved, so the tables exist but the backfill is stalled
      // and no schema index has been created yet.
      await Utils.delay(0)

      let _ = await sql->Postgres.unsafe(`CREATE INDEX "A_b_id" ON "${pgSchema}"."B"("c_id");`)

      source.resolveGetHeightOrThrow(100)
      source.resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=100)
      await indexer.waitUntilReady()

      let conflicting = await findIndexes(~sql, ~tableName="B", ~columns=["c_id"], ~pgSchema)
      let aIndexes = await findIndexes(~sql, ~tableName="A", ~columns=["b_id"], ~pgSchema)

      t.expect(
        (
          await indexer.metric("envio_progress_ready"),
          conflicting->Array.map(entry => entry.name),
          aIndexes->Array.map(entry => (entry->isValid, entry->isPartial, entry->predicate)),
        ),
        ~message="The conflicting index is left alone and A(b_id) still gets a usable index of its own",
      ).toEqual(([{value: "1", labels: dict{"chainId": "1337"}}], ["A_b_id"], [(true, false, None)]))

      t.expect(
        aIndexes->Array.map(entry => entry.name),
        ~message="The generated name can't be the one an unrelated index took",
      ).toEqual([aBIdIndexName])
    },
  )
})

describe("Automatic getWhere indexes", () => {
  // `optionalStringToTestLinkedEntities` carries no @index, so nothing creates
  // an index for it up front. Querying it has to build one mid-backfill and
  // still return the right rows.
  scenario->Scenario.it(
    "Are built mid-backfill by the first query that needs one",
    ~sources=[{chain: 1337}],
    async (~t, ~indexer, ~source) => {
      let source = source(1337)
      let {sql, pgSchema} = indexer.pg
      let matched = ref([])
      let optionalColumn = "optionalStringToTestLinkedEntities"

      source.resolveGetHeightOrThrow(1000)

      source.resolveGetItemsOrThrow(
        [
          {
            blockNumber: 10,
            logIndex: 0,
            handler: async args => {
              let context = args.context->asContext
              context.a.set({
                id: "1",
                b_id: "b",
                optionalStringToTestLinkedEntities: Some("wanted"),
              })
              context.a.set({
                id: "2",
                b_id: "b",
                optionalStringToTestLinkedEntities: Some("other"),
              })
              context.a.set({
                id: "3",
                b_id: "b",
                optionalStringToTestLinkedEntities: Some("wanted"),
              })
            },
          },
        ],
        ~latestFetchedBlockNumber=10,
      )
      await indexer.getBatchWritePromise()

      t.expect(
        await findIndexes(~sql, ~tableName="A", ~columns=[optionalColumn], ~pgSchema),
        ~message="Nothing has queried the field yet, so no index exists for it",
      ).toEqual([])

      await MockSource.waitItemsQuery(source)
      source.resolveGetItemsOrThrow(
        [
          {
            blockNumber: 20,
            logIndex: 0,
            handler: async args => {
              let context = args.context->asContext
              let rows = await context.a.getWhere({
                optionalStringToTestLinkedEntities: {_eq: Some("wanted")},
              })
              matched := rows->Array.map(entity => entity.id)->Array.toSorted(String.compare)
            },
          },
        ],
        ~latestFetchedBlockNumber=20,
      )
      await indexer.getBatchWritePromise()

      t.expect(
        (
          matched.contents,
          (await findIndexes(~sql, ~tableName="A", ~columns=[optionalColumn], ~pgSchema))->Array.map(
            entry => (entry.name, entry->isValid),
          ),
          await findIndexes(~sql, ~tableName="A", ~columns=["b_id"], ~pgSchema),
          await readyAtByChainId(~sql, ~pgSchema),
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
      await MockSource.waitItemsQuery(source)
      // The backfill is chunked into a query per range; the chain only reaches
      // the head once every one of them is answered.
      source.drainItemsQueries(~latestFetchedBlockNumber=1000)
      await indexer.waitUntilReady()

      t.expect(
        (
          (await findIndexes(
            ~sql,
            ~tableName="A",
            ~columns=[optionalColumn],
            ~pgSchema,
          ))->Array.length,
          (await findIndexes(~sql, ~tableName="A", ~columns=["b_id"], ~pgSchema))->Array.map(
            entry => entry.name,
          ),
          await readyAtByChainId(~sql, ~pgSchema),
        ),
        ~message="Reaching ready adds the schema indexes without disturbing the automatic one",
      ).toEqual((1, [aBIdIndexName], [(ChainId.fromInt(1337), true)]))
    },
  )
})
