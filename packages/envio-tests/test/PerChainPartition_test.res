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
let longCounter = entityConfig(longName)

let chainIds = [1->ChainId.fromInt, 137->ChainId.fromInt]

describe("Per-chain entity partitions", () => {
  it("Names one partition per chain, and only for a per-chain entity", t => {
    t.expect(
      chainIds->Array.map(chainId => PgStorage.partitionTableName(~entityConfig=counter, ~chainId)),
    ).toEqual(["Counter$1", "Counter$137"])
  })

  // `$` can't appear in a GraphQL entity name, so a partition can never take a
  // name another entity's table claims. Past 63 bytes the readable half is cut
  // and the entity index keeps what's left unique.
  it("Fits a long partition name into the identifier limit", t => {
    // What a truncated name keeps whole, and so what the readable half is cut
    // down to make room for.
    let suffix = `$${longCounter.index->Int.toString}$137`
    let names =
      chainIds->Array.map(
        chainId => PgStorage.partitionTableName(~entityConfig=longCounter, ~chainId),
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

let ownerIndexName = "Counter_owner_0nly2t9mp5"

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
      let relations: array<relation> = await sql->Sql.queryForTests(
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
      let catalog = await sql->PgCatalog.indexes(~pgSchema)
      let ownerIndex =
        catalog
        ->Array.find(index => index.tableName === "Counter" && index.columns == ["owner"])
        ->Option.map(index => (index.tableName, index.name, index.isValid))

      let plan: array<{
        "QUERY PLAN": string,
      }> = await sql->Sql.queryForTests(
        `EXPLAIN SELECT * FROM "${pgSchema}"."Counter" WHERE "chainId" = 137`,
      )

      await indexer.stop()

      t.expect((
        rows->Array.toSorted((a, b) => Int.compare(a.chainId, b.chainId)),
        relations,
        ownerIndex,
        // Nothing anywhere in the schema — partitions included — is unusable.
        catalog->Array.filterMap(index => index.isValid ? None : Some(index.name)),
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
