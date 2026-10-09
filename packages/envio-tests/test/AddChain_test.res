open Vitest

// A chain added to config.yaml after the database was built joins it the moment
// `envio start --chain <id>` names it: the schema gains the chain's row,
// partitions and addresses, and the chains already there are left as they were.

let schema = `
type Counter {
  id: ID!
  count: BigInt!
}
`

let chainYaml = (chainId, ~startBlock="1") =>
  `
  - id: ${chainId->Int.toString}
    rpc:
      url: https://rpc${chainId->Int.toString}.example.test
      for: sync
    start_block: ${startBlock}
    contracts:
      - name: Token
        address: "0x0000000000000000000000000000000000000001"
`

let configYaml = (~chains) =>
  `
name: add-chain
disable_default_cross_chain: true
contracts:
  - name: Token
    events:
      - event: Transfer()
chains:${chains->Array.join("")}`

let deployed = Scenario.make(~schema, ~configYaml=configYaml(~chains=[chainYaml(1)]))

let withChain137 = Scenario.make(
  ~schema,
  ~configYaml=configYaml(~chains=[chainYaml(1), chainYaml(137)]),
)

type counterRow = {
  id: string,
  count: bigint,
  @as("chainId") chainId: int,
}

type counterOps = {set: {"id": string, "count": bigint} => unit}
type handlerContext = {@as("Counter") counter: counterOps}

let bump = (count: bigint): MockSource.itemMock => {
  blockNumber: 5,
  logIndex: 0,
  handler: async args => {
    let context = args.context->(Utils.magic: Internal.handlerContext => handlerContext)
    context.counter.set({"id": "total", "count": count})
  },
}

let catchUp = async (~indexer: IndexerRunner.t, ~source: MockSource.t, ~items) => {
  source.resolveGetHeightOrThrow(100)
  source.resolveGetItemsOrThrow(items, ~latestFetchedBlockNumber=100)
  await indexer.waitUntilReady()
  await indexer.waitUntilIdle()
}

// The edited config.yaml, with the chains the deployed run already drives
// answered by their own sources and every other chain by a fresh one.
// `~autoHeight` answers a fresh chain's height during startup, before a test
// body could, for a `latest` start block to resolve against.
let edited = (
  scenario: Scenario.t,
  ~deployedSources: array<(int, MockSource.t)>,
  ~autoHeight=?,
) => {
  let sources =
    scenario.config.chainMap
    ->ChainMap.keys
    ->Array.map(chainId => {
      let chain = chainId->ChainId.toInt
      switch deployedSources->Array.find(((deployed, _)) => deployed === chain) {
      | Some(deployed) => deployed
      | None => (chain, MockSource.make(Scenario.defaultMethods, ~chainId=chain, ~autoHeight?))
      }
    })
  (scenario.config->Scenario.withMockSources(~sources), sources)
}

let sourceOf = (sources: array<(int, MockSource.t)>, chain) =>
  sources->Array.find(((mocked, _)) => mocked === chain)->Option.getOrThrow->Pair.second

let chainRows = async (indexer: IndexerRunner.t) => {
  let {sql, pgSchema} = indexer.pg
  let rows: array<{
    "id": ChainId.t,
    "progress_block": int,
  }> = await sql->Sql.queryForTests(
    `SELECT "id", "progress_block" FROM "${pgSchema}"."envio_chains" ORDER BY "id";`,
  )
  rows->Array.map(row => (row["id"]->ChainId.toString, row["progress_block"]))
}

let startBlocks = async (indexer: IndexerRunner.t) => {
  let {sql, pgSchema} = indexer.pg
  let rows: array<{
    "id": ChainId.t,
    "start_block": int,
  }> = await sql->Sql.queryForTests(
    `SELECT "id", "start_block" FROM "${pgSchema}"."envio_chains" ORDER BY "id";`,
  )
  rows->Array.map(row => (row["id"]->ChainId.toString, row["start_block"]))
}

let counterPartitions = async (indexer: IndexerRunner.t) => {
  let {sql, pgSchema} = indexer.pg
  let rows: array<{
    "name": string,
  }> = await sql->Sql.queryForTests(
    `SELECT c.relname AS "name"
     FROM pg_inherits inh
     JOIN pg_class c ON c.oid = inh.inhrelid
     JOIN pg_class p ON p.oid = inh.inhparent
     JOIN pg_namespace n ON n.oid = p.relnamespace
     WHERE n.nspname = '${pgSchema}' AND p.relname = 'Counter'
     ORDER BY c.relname`,
  )
  rows->Array.map(row => row["name"])
}

describe("envio start --chain with a chain the database doesn't have yet", () => {
  deployed->Scenario.it(
    "Adds the chain and indexes it, leaving the deployed chain as it was",
    ~sources=[{chain: 1}],
    ~captureLogs=true,
    async (~t, ~indexer, ~source) => {
      await catchUp(~indexer, ~source=source(1), ~items=[bump(1n)])

      let (config, sources) = withChain137->edited(~deployedSources=[(1, source(1))])
      let added = await indexer.restart(~config, ~chains=[ChainId.fromInt(137)], ())
      await catchUp(~indexer=added, ~source=sources->sourceOf(137), ~items=[bump(10n)])

      // Named again, the chain is already there: a plain resume.
      let resumed = await added.restart(~chains=[ChainId.fromInt(137)], ())

      let rows: array<counterRow> = await resumed.query("Counter")
      t.expect(
        (
          rows->Array.toSorted((a, b) => Int.compare(a.chainId, b.chainId)),
          await chainRows(resumed),
          await counterPartitions(resumed),
          (await resumed.queryAddresses())->Array.map(
            row => (row.chainId->ChainId.toString, row.contractName),
          ),
          resumed.logs()->Array.filter(entry => entry.msg->String.startsWith("Adding the chain")),
        ),
        ~message="Chain 137 gets a row, a partition and its config addresses, and indexes into them. Chain 1 keeps what it had, and the operator is told once",
      ).toEqual((
        [{id: "total", count: 1n, chainId: 1}, {id: "total", count: 10n, chainId: 137}],
        [("1", 100), ("137", 100)],
        ["Counter$1", "Counter$137"],
        [("1", "Token"), ("137", "Token")],
        [
          (
            {
              msg: "Adding the chain to the existing indexer storage...",
              params: dict{"chainId": JSON.Encode.int(137)},
            }: IndexerRunner.logEntry
          ),
        ],
      ))
    },
  )

  let clickHouseOnly: array<Scenario.unsupported> = [
    {backend: #postgres, reason: "asserts against a ClickHouse server"},
  ]
  Scenario.make(
    ~schema,
    ~configYaml=configYaml(~chains=[chainYaml(1)]),
    ~unsupported=clickHouseOnly,
  )->Scenario.it(
    "Mirrors the added chain into ClickHouse alongside the deployed one",
    ~sources=[{chain: 1}],
    async (~t, ~indexer, ~source) => {
      await catchUp(~indexer, ~source=source(1), ~items=[bump(1n)])

      let (config, sources) =
        Scenario.make(
          ~schema,
          ~configYaml=configYaml(~chains=[chainYaml(1), chainYaml(137)]),
          ~unsupported=clickHouseOnly,
        )->edited(~deployedSources=[(1, source(1))])
      let added = await indexer.restart(~config, ~chains=[ChainId.fromInt(137)], ())
      await catchUp(~indexer=added, ~source=sources->sourceOf(137), ~items=[bump(10n)])

      let rows = await TestClickHouse.query(
        `SELECT id, count, chainId FROM \`${TestClickHouse.currentDatabase()}\`.\`Counter\` ORDER BY chainId FORMAT JSONEachRow`,
      )
      t.expect(rows->String.trim).toEqual(`{"id":"total","count":"1","chainId":1}
{"id":"total","count":"10","chainId":137}`)
    },
  )

  deployed->Scenario.it(
    "Resumes every chain in one process once the added chain is there",
    ~sources=[{chain: 1}],
    async (~t, ~indexer, ~source) => {
      await catchUp(~indexer, ~source=source(1), ~items=[])
      let (config, sources) = withChain137->edited(~deployedSources=[(1, source(1))])
      let added = await indexer.restart(~config, ~chains=[ChainId.fromInt(137)], ())
      await catchUp(~indexer=added, ~source=sources->sourceOf(137), ~items=[])

      let unsplit = await added.restart()

      t.expect(await chainRows(unsplit)).toEqual([("1", 100), ("137", 100)])
    },
  )

  deployed->Scenario.it(
    "Resolves an added chain's latest start block against its head",
    ~sources=[{chain: 1}],
    async (~t, ~indexer, ~source) => {
      await catchUp(~indexer, ~source=source(1), ~items=[])
      let (config, _) =
        Scenario.make(
          ~schema,
          ~configYaml=configYaml(~chains=[chainYaml(1), chainYaml(137, ~startBlock="latest")]),
        )->edited(~deployedSources=[(1, source(1))], ~autoHeight=500)

      let added = await indexer.restart(~config, ~chains=[ChainId.fromInt(137)], ())

      t.expect(await startBlocks(added)).toEqual([("1", 1), ("137", 500)])
    },
  )

  deployed->Scenario.it(
    "Asks for a set-up database before any --chain process starts",
    ~sources=[{chain: 1}],
    async (~t, ~indexer, ~source) => {
      await catchUp(~indexer, ~source=source(1), ~items=[])
      await indexer.stop()
      let {sql, pgSchema} = indexer.pg
      let _ = await sql->Sql.queryForTests(`DROP SCHEMA "${pgSchema}" CASCADE;`)

      let outcome = switch await indexer.restart(~chains=[ChainId.fromInt(1)], ()) {
      | restarted => Migration.Resumed(await Migration.storedChainIds(restarted))
      | exception JsExn(e) => Migration.outcomeOfRefusal(e->JsExn.message->Option.getOr(""))
      }

      t.expect(outcome).toEqual(
        Failed(
          "`envio start --chain` needs a database that is already set up. Run `envio local db-migrate up` once with the full config, then start a process per chain.",
        ),
      )
    },
  )
})
