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

let chainYaml = (chainId, address) =>
  `
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
  ~supervised=false,
  ~configYaml=`
name: schema-indexes${contractsYaml}chains:${chainYaml(
      1337,
      "0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3",
    )}`,
  ~schema,
)

// An `end_block` the chain never reaches: the indexer still counts itself caught
// up once progress sits at the head, so the deferred indexes are owed then, not
// at the unreachable end block.
let unreachableEndBlockScenario = Scenario.make(
  ~supervised=false,
  ~configYaml=`
name: schema-indexes-unreachable-end${contractsYaml}chains:
  - id: 1337
    rpc:
      url: https://rpc1337.example.test
      for: sync
    start_block: 1
    end_block: 1000000
    contracts:
      - name: Gravatar
        address: "0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3"
`,
  ~schema,
)

// A `start_block` past the head: the chain is at its head from the first moment
// and never has a batch to process, so nothing ever writes its progress row.
let aheadOfHeadScenario = Scenario.make(
  ~supervised=false,
  ~configYaml=`
name: schema-indexes-ahead-of-head${contractsYaml}chains:
  - id: 1337
    rpc:
      url: https://rpc1337.example.test
      for: sync
    start_block: 5000
    contracts:
      - name: Gravatar
        address: "0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3"
`,
  ~schema,
)

let multichainScenario = Scenario.make(
  ~supervised=false,
  ~configYaml=`
name: schema-indexes-multichain${contractsYaml}chains:${chainYaml(
      100,
      "0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3",
    )}${chainYaml(1337, "0x3B2f78c5BF6D9C12Ee1225D5F374aa91204580c3")}`,
  ~schema,
)

// Every index on `tableName` whose key columns start with `columns`, so an
// assertion can say what the schema holds rather than what SQL was emitted.
let findIndexes = (~sql, ~tableName, ~columns, ~pgSchema) =>
  sql->PgCatalog.leadingWith(~pgSchema, ~tableName, ~columns)

let indexNames = async (~sql, ~pgSchema) =>
  (await sql->PgCatalog.indexes(~pgSchema))->Array.map(index => index.name)

let aBIdIndexName = "A_b_id_556h9mdu8a"

let readyAtByChainId = async (indexer: IndexerRunner.t) =>
  (await indexer.queryChains())->Array.map(chain => (chain.id, chain.readyAt->Option.isSome))

// Timestamps rather than flags, for the chains that have to share one.
let readyAtTimesByChainId = async (indexer: IndexerRunner.t) =>
  (await indexer.queryChains())->Array.map(chain => (
    chain.id,
    chain.readyAt->Option.map(Date.toISOString),
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
  aheadOfHeadScenario->Scenario.it(
    "Are committed for a chain that starts past the head and never processes a batch",
    ~sources=[{chain: 1337}],
    async (~t, ~indexer, ~source) => {
      let source = source(1337)

      source.resolveGetHeightOrThrow(100)
      await indexer.waitUntilReady()
      await indexer.waitUntilIdle()

      t.expect(
        await readyAtByChainId(indexer),
        ~message="A chain with nothing to do is caught up",
      ).toEqual([(ChainId.fromInt(1337), true)])
      await indexer.inPostgres(
        async ({sql, pgSchema}) =>
          t.expect(
            (await findIndexes(~sql, ~tableName="A", ~columns=["b_id"], ~pgSchema))->Array.map(
              entry => entry.name,
            ),
            ~message="The indexes are owed on being caught up",
          ).toEqual([aBIdIndexName]),
      )
    },
  )

  unreachableEndBlockScenario->Scenario.it(
    "Are committed once the chain sits at the head, even with an end block it never reaches",
    ~sources=[{chain: 1337}],
    async (~t, ~indexer, ~source) => {
      let source = source(1337)

      source.resolveGetHeightOrThrow(100)
      await source.expectItemsQueries([
        {fromBlock: 1, reply: Respond({items: [], latestFetchedBlockNumber: 100})},
      ])
      await indexer.waitUntilReady()
      await indexer.waitUntilIdle()

      t.expect(
        await readyAtByChainId(indexer),
        ~message="Sitting at the head is what readiness is owed on, not reaching the end block",
      ).toEqual([(ChainId.fromInt(1337), true)])
      await indexer.inPostgres(
        async ({sql, pgSchema}) =>
          t.expect(
            (await findIndexes(~sql, ~tableName="A", ~columns=["b_id"], ~pgSchema))->Array.map(
              entry => entry.name,
            ),
            ~message="Sitting at the head is what the indexes are owed on, not reaching the end block",
          ).toEqual([aBIdIndexName]),
      )
    },
  )

  scenario->Scenario.it(
    "Are absent through backfill, committed with ready_at, and kept across a restart",
    ~sources=[{chain: 1337}],
    async (~t, ~indexer, ~source) => {
      let source = source(1337)
      await Utils.delay(0)

      t.expect(
        (await readyAtByChainId(indexer), await indexer.metric("envio_progress_ready")),
        ~message="Nothing is ready through backfill",
      ).toEqual(([(ChainId.fromInt(1337), false)], [{value: "0", labels: dict{"chainId": "1337"}}]))
      await indexer.inPostgres(
        async ({sql, pgSchema}) =>
          t.expect(
            await findIndexes(~sql, ~tableName="A", ~columns=["b_id"], ~pgSchema),
            ~message="Backfill runs without the schema's read indexes",
          ).toEqual([]),
      )

      source.resolveGetHeightOrThrow(100)
      await source.expectItemsQueries([
        {fromBlock: 1, reply: Respond({items: [], latestFetchedBlockNumber: 100})},
      ])
      await indexer.waitUntilReady()

      t.expect(
        (await readyAtByChainId(indexer), await indexer.metric("envio_progress_ready")),
        ~message="ready_at is committed once the chain is caught up",
      ).toEqual(([(ChainId.fromInt(1337), true)], [{value: "1", labels: dict{"chainId": "1337"}}]))
      await indexer.inPostgres(
        async ({sql, pgSchema}) =>
          t.expect(
            (await findIndexes(~sql, ~tableName="A", ~columns=["b_id"], ~pgSchema))->Array.map(
              entry => (entry.name, entry.isValid, entry.isPartial, entry.method),
            ),
            ~message="ready_at is only committed once every schema-defined index exists",
          ).toEqual([(aBIdIndexName, true, false, "btree")]),
      )

      let {sql, pgSchema} = indexer.pg
      let indexesBeforeRestart = await indexNames(~sql, ~pgSchema)
      let restarted = await indexer.restart()
      await restarted.waitUntilIdle()

      t.expect(
        (await indexNames(~sql, ~pgSchema), await readyAtByChainId(indexer)),
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

      source.resolveGetHeightOrThrow(100)
      await source.expectItemsQueries([
        {fromBlock: 1, reply: Respond({items: [], latestFetchedBlockNumber: 100})},
      ])
      while gate.entered.contents === 0 {
        await Utils.delay(0)
      }

      t.expect(
        (await readyAtByChainId(indexer), await indexer.metric("envio_progress_ready")),
        ~message="Caught up to the head, but the indexes aren't committed so nothing is ready",
      ).toEqual(([(ChainId.fromInt(1337), false)], [{value: "0", labels: dict{"chainId": "1337"}}]))
      await indexer.inPostgres(async ({sql, pgSchema}) =>
        t.expect(
          await findIndexes(~sql, ~tableName="A", ~columns=["b_id"], ~pgSchema),
          ~message="The indexes aren't committed while finalization is held",
        ).toEqual([])
      )

      gate.release()
      await indexer.waitUntilReady()

      t.expect(await readyAtByChainId(indexer)).toEqual([(ChainId.fromInt(1337), true)])
      await indexer.inPostgres(async ({sql, pgSchema}) =>
        t.expect(
          (await findIndexes(~sql, ~tableName="A", ~columns=["b_id"], ~pgSchema))->Array.map(
            entry => entry.name,
          ),
        ).toEqual([aBIdIndexName])
      )
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
      await source.expectItemsQueries([
        {fromBlock: 1, reply: Respond({items: [], latestFetchedBlockNumber: 100})},
      ])
      while gate.entered.contents === 0 {
        await Utils.delay(0)
      }

      t.expect(
        (finalizeCalls.contents, await indexer.metric("envio_progress_ready")),
        ~message="Finalization is under way and nothing is ready while it is held",
      ).toEqual((1, [{value: "0", labels: dict{"chainId": "1337"}}]))

      let heightCallsAtHead = source.getHeightOrThrowCalls->Array.length

      // A height update while the build is held: the chain fetches the new range
      // and its response schedules processing again.
      await MockSource.waitHeightQuery(source, ~since=heightCallsAtHead)
      source.resolveGetHeightOrThrow(200)
      await source.expectItemsQueries([
        {fromBlock: 101, reply: Respond({items: [], latestFetchedBlockNumber: 200})},
      ])
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
      // Counted from where this pass began: a multichain scenario runs a second
      // time behind the barrier, over the same counter.
      let before = multichainFinalizeCalls.contents
      let finalizeCalls = () => multichainFinalizeCalls.contents - before
      let chainA = source(100)
      let chainB = source(1337)

      chainA.resolveGetHeightOrThrow(100)
      chainB.resolveGetHeightOrThrow(100)

      await chainA.expectItemsQueries([
        {fromBlock: 1, reply: Respond({items: [], latestFetchedBlockNumber: 100})},
      ])
      await indexer.getBatchWritePromise()

      t.expect(
        (finalizeCalls(), await readyAtByChainId(indexer)),
        ~message="Chain A is at its head, but chain B is still backfilling",
      ).toEqual((0, [(ChainId.fromInt(100), false), (ChainId.fromInt(1337), false)]))

      await chainB.expectItemsQueries([
        {fromBlock: 1, reply: Respond({items: [], latestFetchedBlockNumber: 100})},
      ])
      await indexer.waitUntilReady()

      let readyAtTimes = await readyAtTimesByChainId(indexer)
      let times = readyAtTimes->Array.map(((_, readyAt)) => readyAt)
      t.expect(
        (
          finalizeCalls(),
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
    ~unsupported=[
      {
        backend: #clickhouse,
        reason: "plants the conflicting index on a Postgres entity table, which the ClickHouse leg has none of",
      },
    ],
    ~sources=[{chain: 1337}],
    async (~t, ~indexer, ~source) => {
      let source = source(1337)
      let {sql, pgSchema} = indexer.pg
      // The height is unresolved, so the tables exist but the backfill is stalled
      // and no schema index has been created yet.
      await Utils.delay(0)

      let _ = await sql->Sql.queryForTests(`CREATE INDEX "A_b_id" ON "${pgSchema}"."B"("c_id");`)

      source.resolveGetHeightOrThrow(100)
      await source.expectItemsQueries([
        {fromBlock: 1, reply: Respond({items: [], latestFetchedBlockNumber: 100})},
      ])
      await indexer.waitUntilReady()

      let conflicting = await findIndexes(~sql, ~tableName="B", ~columns=["c_id"], ~pgSchema)
      let aIndexes = await findIndexes(~sql, ~tableName="A", ~columns=["b_id"], ~pgSchema)

      t.expect(
        (
          await indexer.metric("envio_progress_ready"),
          conflicting->Array.map(entry => entry.name),
          aIndexes->Array.map(entry => (entry.isValid, entry.isPartial)),
        ),
        ~message="The conflicting index is left alone and A(b_id) still gets a usable index of its own",
      ).toEqual(([{value: "1", labels: dict{"chainId": "1337"}}], ["A_b_id"], [(true, false)]))

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
      let matched = ref([])
      let optionalColumn = "optionalStringToTestLinkedEntities"

      source.resolveGetHeightOrThrow(1000)

      await source.expectItemsQueries([
        {
          fromBlock: 1,
          reply: Respond({
            items: [
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
            latestFetchedBlockNumber: 10,
          }),
        },
      ])
      await indexer.getBatchWritePromise()

      await indexer.inPostgres(
        async ({sql, pgSchema}) =>
          t.expect(
            await findIndexes(~sql, ~tableName="A", ~columns=[optionalColumn], ~pgSchema),
            ~message="Nothing has queried the field yet, so no index exists for it",
          ).toEqual([]),
      )

      await source.expectItemsQueries([
        {
          fromBlock: 11,
          reply: Respond({
            items: [
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
            latestFetchedBlockNumber: 20,
          }),
        },
      ])
      await indexer.getBatchWritePromise()

      t.expect(
        (matched.contents, await readyAtByChainId(indexer)),
        ~message="The query returns the right rows during backfill",
      ).toEqual((["1", "3"], [(ChainId.fromInt(1337), false)]))
      await indexer.inPostgres(
        async ({sql, pgSchema}) =>
          t.expect(
            (
              (
                await findIndexes(~sql, ~tableName="A", ~columns=[optionalColumn], ~pgSchema)
              )->Array.map(entry => (entry.name, entry.isValid)),
              await findIndexes(~sql, ~tableName="A", ~columns=["b_id"], ~pgSchema),
            ),
            ~message="The query builds its own index during backfill, while the schema's own indexes stay deferred",
          ).toEqual(([("A_optionalStringToTestLinkedEntities_cedvgf89cu", true)], [])),
      )

      // The automatic index is the indexer's own, so finalizing must leave it be.
      // The backfill is chunked into a query per range; the chain only reaches
      // the head once every one of them is answered.
      await source.respondEmptyUpTo(1000)
      await indexer.waitUntilReady()

      t.expect(await readyAtByChainId(indexer)).toEqual([(ChainId.fromInt(1337), true)])
      await indexer.inPostgres(
        async ({sql, pgSchema}) =>
          t.expect(
            (
              (
                await findIndexes(~sql, ~tableName="A", ~columns=[optionalColumn], ~pgSchema)
              )->Array.length,
              (await findIndexes(~sql, ~tableName="A", ~columns=["b_id"], ~pgSchema))->Array.map(
                entry => entry.name,
              ),
            ),
            ~message="Reaching ready adds the schema indexes without disturbing the automatic one",
          ).toEqual((1, [aBIdIndexName])),
      )
    },
  )
})
