open Vitest

// A 60-character entity name: `$1` still fits Postgres' 63-byte identifier
// limit, `$137` doesn't — so one entity exercises both naming branches.
let longName = "CounterWith60CharacterName__________________________________"

// `owner` is indexed so the schema's own index lands on a partitioned table:
// Postgres cascades it to every partition, and only the parent's belongs to the
// indexer.
let schema = `
type Counter {
  id: ID!
  count: BigInt!
  owner: String! @index
}
type GlobalCounter @crossChain {
  id: ID!
  count: BigInt!
}
type ${longName} {
  id: ID!
  count: BigInt!
}
`

let configYaml = `
name: per-chain-partition
disable_default_cross_chain: true
contracts:
  - name: Token
    events:
      - event: Transfer()
chains:
  - id: 1
    rpc:
      url: https://rpc1.example.test
      for: sync
    start_block: 1
    contracts:
      - name: Token
        address: "0x0000000000000000000000000000000000000001"
  - id: 137
    rpc:
      url: https://rpc137.example.test
      for: sync
    start_block: 1
    contracts:
      - name: Token
        address: "0x0000000000000000000000000000000000000001"
`

let config = InternalTestIndexer.fromUserApi(~configYaml, ~schema).config
let entityConfig = name => config->IndexerRunner.entityConfigByName(name)
let counter = entityConfig("Counter")
let globalCounter = entityConfig("GlobalCounter")
let longCounter = entityConfig(longName)

let chainIds = [1->ChainId.fromInt, 137->ChainId.fromInt]

let createQueries = entityConfig =>
  PgStorage.makeCreateEntityTableQueries(
    entityConfig,
    ~pgSchema="public",
    ~isNumericArrayAsText=false,
    ~chainIds,
  )

describe("Per-chain entity partition DDL", () => {
  // The history table trails the partitions and stays plain: it is only ever
  // read by checkpoint, never by chain.
  it("Partitions a per-chain entity by chain, one partition per configured chain", t => {
    t.expect(counter->createQueries).toEqual([
      `CREATE TABLE IF NOT EXISTS "public"."Counter"("id" TEXT NOT NULL, "count" NUMERIC NOT NULL, "owner" TEXT NOT NULL, "chainId" INTEGER NOT NULL, PRIMARY KEY("id", "chainId")) PARTITION BY LIST ("chainId");`,
      `CREATE TABLE IF NOT EXISTS "public"."Counter$1" PARTITION OF "public"."Counter" FOR VALUES IN (1);`,
      `CREATE TABLE IF NOT EXISTS "public"."Counter$137" PARTITION OF "public"."Counter" FOR VALUES IN (137);`,
      `CREATE TABLE IF NOT EXISTS "public"."envio_history_Counter"("id" TEXT NOT NULL, "count" NUMERIC, "owner" TEXT, "chainId" INTEGER NOT NULL, "envio_checkpoint_id" BIGINT NOT NULL, "envio_change" "public".ENVIO_HISTORY_CHANGE NOT NULL, PRIMARY KEY("id", "chainId", "envio_checkpoint_id"));`,
    ])
  })

  it("Leaves a cross-chain entity unpartitioned", t => {
    t.expect(globalCounter->createQueries).toEqual([
      `CREATE TABLE IF NOT EXISTS "public"."GlobalCounter"("id" TEXT NOT NULL, "count" NUMERIC NOT NULL, PRIMARY KEY("id"));`,
      `CREATE TABLE IF NOT EXISTS "public"."envio_history_GlobalCounter"("id" TEXT NOT NULL, "count" NUMERIC, "envio_checkpoint_id" BIGINT NOT NULL, "envio_change" "public".ENVIO_HISTORY_CHANGE NOT NULL, PRIMARY KEY("id", "envio_checkpoint_id"));`,
    ])
  })

  // `$` can't appear in a GraphQL entity name, so a partition can never take a
  // name another entity's table claims. Past 63 bytes the readable half is cut
  // and the entity index keeps what's left unique.
  it("Fits a long partition name into the identifier limit", t => {
    // What a truncated name keeps whole, and so what the readable half is cut
    // down to make room for.
    let suffix = `$${longCounter.index->Int.toString}$137`
    let names =
      longCounter
      ->createQueries
      ->Array.filterMap(
        query =>
          query->String.includes("PARTITION OF") ? query->String.split(`"`)->Array.get(3) : None,
      )
    // Chain 1 leaves the name whole under the limit; chain 137 pushes it over,
    // and the result sits exactly on the limit rather than past it.
    t.expect((names, names->Array.map(String.length))).toEqual((
      [
        `${longName}$1`,
        longName->String.slice(~start=0, ~end=Table.maxPgTableNameLength - suffix->String.length) ++
          suffix,
      ],
      [62, Table.maxPgTableNameLength],
    ))
  })

})

describe("A changed chain set can't reach an existing schema", () => {
  let publicConfig = configYaml =>
    Core.fromUserApi(~schema, configYaml).config->JSON.parseOrThrow->Config.stripSensitiveData

  // Chain 137 is last in the yaml, so cutting it off drops exactly that chain.
  let singleChainConfigYaml =
    configYaml->String.split("  - id: 137")->Array.get(0)->Option.getOrThrow

  it("Reports a dropped chain as an incompatible config change", t => {
    t.expect(
      Config.diffPaths(
        ~stored=publicConfig(configYaml),
        ~current=publicConfig(singleChainConfigYaml),
      ),
    ).toEqual(["evm.chains.polygon"])
  })
})

type counterRow = {
  id: string,
  count: bigint,
  owner: string,
  @as("chainId") chainId: int,
}

type counterOps = {set: {"id": string, "count": bigint, "owner": string} => unit}
type handlerContext = {@as("Counter") counter: counterOps}

let scenario = Scenario.make(~schema, ~configYaml)

let methods: array<MockSource.method> = [#getHeightOrThrow, #getItemsOrThrow]

let bump = (count: bigint): MockSource.itemMock => {
  blockNumber: 5,
  logIndex: 0,
  handler: async args => {
    let context = args.context->(Utils.magic: Internal.handlerContext => handlerContext)
    context.counter.set({"id": "total", "count": count, "owner": "alice"})
  },
}

type relation = {
  @as("name") name: string,
  @as("kind") kind: string,
  @as("parent") parent: string,
}

let ownerIndexName =
  IndexDefinition.single(~tableName="Counter", ~column="owner")->IndexDefinition.name

describe("Per-chain entity partitions against Postgres", () => {
  scenario->Scenario.it(
    "Creates the partitions, prunes a chain-filtered read to one, and round-trips rows",
    ~sources=[{chain: 1, methods}, {chain: 137, methods}],
    async (~t, ~indexer, ~source) => {
      let source1 = source(1)
      let source137 = source(137)

      source1.resolveGetHeightOrThrow(300)
      source137.resolveGetHeightOrThrow(300)

      source1.resolveGetItemsOrThrow([bump(1n)], ~latestFetchedBlockNumber=300)
      source137.resolveGetItemsOrThrow([bump(10n)], ~latestFetchedBlockNumber=300)
      await indexer.getBatchWritePromise()
      // The schema's read indexes are deferred past backfill, so the catalog
      // only holds them once every chain has reported ready.
      await indexer.waitUntilReady()
      await indexer.waitUntilIdle()

      let rows: array<counterRow> = await indexer.query("Counter")

      let {sql, pgSchema} = indexer.pg

      // Every relation the Counter entity owns: the parent, its partitions, and
      // its history table — with what each one is attached to.
      let relations: array<relation> = await sql->Postgres.unsafe(
        `SELECT c.relname AS "name", c.relkind::text AS "kind", COALESCE(p.relname, '') AS "parent"
         FROM pg_class c
         JOIN pg_namespace n ON n.oid = c.relnamespace
         LEFT JOIN pg_inherits inh ON inh.inhrelid = c.oid
         LEFT JOIN pg_class p ON p.oid = inh.inhparent
         WHERE n.nspname = '${pgSchema}'
           AND c.relkind IN ('r', 'p')
           AND c.relname ~ '^(envio_history_)?Counter([$][0-9]+)?$'
         ORDER BY c.relname`,
      )

      // Postgres cascades a partitioned index down to every partition. The
      // indexer declared its index on the parent, so that is what has to
      // satisfy the declaration — a child's copy must never stand in for it.
      let catalog =
        IndexCatalog.fromRows(
          ~rows=(await sql->Postgres.unsafe(IndexCatalog.makeQuery(~pgSchema)))->S.parseOrThrow(
            IndexCatalog.rowsSchema,
          ),
        )
      let ownerIndex =
        catalog
        ->IndexCatalog.find(
          IndexDefinition.single(~tableName="Counter", ~column="owner"),
          ~coverage=Exact,
        )
        ->Option.map((entry: IndexCatalog.entry) => (entry.tableName, entry.name, entry.isValid))

      let plan: array<{
        "QUERY PLAN": string,
      }> = await sql->Postgres.unsafe(
        `EXPLAIN SELECT * FROM "${pgSchema}"."Counter" WHERE "chainId" = 137`,
      )

      await indexer.stop()

      t.expect((
        rows->Array.toSorted((a, b) => Int.compare(a.chainId, b.chainId)),
        relations,
        ownerIndex,
        // Nothing anywhere in the schema — partitions included — is unusable.
        catalog->IndexCatalog.invalidNames,
        // Only chain 137's partition survives planning; the other is pruned.
        plan
        ->Array.map(row => row["QUERY PLAN"])
        ->Array.filterMap(
          line =>
            line
            ->String.match(/Counter\$\d+/)
            ->Option.flatMap(m => m->Array.get(0)->Option.getOr(None)),
        ),
      )).toEqual((
        [
          {id: "total", count: 1n, owner: "alice", chainId: 1},
          {id: "total", count: 10n, owner: "alice", chainId: 137},
        ],
        [
          {name: "Counter", kind: "p", parent: ""},
          {name: "Counter$1", kind: "r", parent: "Counter"},
          {name: "Counter$137", kind: "r", parent: "Counter"},
          {name: "envio_history_Counter", kind: "r", parent: ""},
        ],
        Some(("Counter", ownerIndexName, true)),
        [],
        [`Counter$137`],
      ))
    },
  )
})

// A chain-scoped statement is reused across batches, so Postgres caches a plan
// for it. With the chain id bound, that cached plan can't prune and has to keep
// every partition — measured at 7 relation locks per execution against 94 on 30
// chains. Writing the chain id into the SQL keeps the cached plan pruned to the
// one partition the statement wants.
let manyChains = [1, 10, 100, 137, 8453, 42161]

let lockScenario = Scenario.make(
  ~schema,
  ~configYaml=configYaml->String.split("chains:")->Array.get(0)->Option.getOrThrow ++
  "chains:" ++
  manyChains
  ->Array.map(id => {
    let id = id->Int.toString
    `
  - id: ${id}
    rpc:
      url: https://rpc${id}.example.test
      for: sync
    start_block: 1
    contracts:
      - name: Token
        address: "0x0000000000000000000000000000000000000001"`
  })
  ->Array.joinUnsafe("") ++ "\n",
)

describe("Reused chain-scoped statements stay pruned", () => {
  lockScenario->Scenario.it(
    "Hold the same locks however often the plan cache reuses them",
    ~sources=manyChains->Array.map((chain): Scenario.sourceMock => {chain, methods}),
    async (~t, ~indexer, ~source) => {
      await Utils.delay(0)
      manyChains->Array.forEach(chain => source(chain).resolveGetHeightOrThrow(300))
      await Utils.delay(0)
      await indexer.stop()

      let {sql, pgSchema} = indexer.pg
      let entityConfig = lockScenario.config->IndexerRunner.entityConfigByName("Counter")
      let chainId = 137->ChainId.fromInt
      // The shape `LoadLayer.scopeFilter` builds for a per-chain entity: the
      // handler's own filter, narrowed to the chain the handler runs on.
      let filter = EntityFilter.And({
        filters: [
          Eq({fieldName: "owner", fieldValue: "alice"->(Utils.magic: string => unknown)}),
          Eq({fieldName: "chainId", fieldValue: chainId->(Utils.magic: ChainId.t => unknown)}),
        ],
      })

      // One transaction pins one connection, so a statement Postgres decides to
      // cache is reused across the runs and its locks accumulate where they can
      // be counted.
      let lockCounts = await sql->Postgres.beginSql(async sql => {
        let storage = PgStorage.make(
          ~sql,
          ~pgSchema,
          ~pgHost="",
          ~pgUser="",
          ~pgPort=0,
          ~pgDatabase="",
          ~pgPassword="",
          ~isHasuraEnabled=false,
          ~ecosystem=Evm,
        )
        let counts = []
        for _ in 1 to 8 {
          let _ = await storage.loadOrThrow(~filter, ~table=entityConfig.table)
          // Scans the entity table for ids that have no history row yet, and
          // runs inside the same write transaction as the delete below.
          await sql->EntityHistory.backfillHistory(
            ~pgSchema,
            ~table=entityConfig.table,
            ~entityIndex=entityConfig.index,
            ~chainId=Some(chainId),
            ~ids=["a"]->Array.map(EntityId.unsafeOfString),
          )
          await sql->PgStorage.deleteByIdsOrThrow(
            ~pgSchema,
            ~ids=["a", "b"]->Array.map(EntityId.unsafeOfString),
            ~table=entityConfig.table,
            ~chainId=Some(chainId),
          )
          let rows: array<{"count": int}> = await sql->Postgres.unsafe(
            `SELECT count(*)::int AS count FROM pg_locks
             WHERE pid = pg_backend_pid() AND locktype = 'relation'`,
          )
          counts->Array.push(rows->Array.getUnsafe(0)->(row => row["count"]))->ignore
        }
        counts
      })

      t.expect(lockCounts->Utils.Set.fromArray->Utils.Set.toArray).toEqual([
        lockCounts->Array.getUnsafe(0),
      ])
    },
  )
})
