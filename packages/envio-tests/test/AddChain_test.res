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

let chainYaml = (chainId, ~contract="Token") =>
  `
  - id: ${chainId->Int.toString}
    rpc:
      url: https://rpc${chainId->Int.toString}.example.test
      for: sync
    start_block: 1
    contracts:
      - name: ${contract}
        address: "0x0000000000000000000000000000000000000001"
`

let configYaml = (~chains, ~contracts=["Token"]) =>
  `
name: add-chain
disable_default_cross_chain: true
contracts:${contracts
    ->Array.map(name =>
      `
  - name: ${name}
    events:
      - event: Transfer()`
    )
    ->Array.join("")}
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

// The edited config.yaml, with chain 1 answered by the source the deployed run
// already drives and every other chain by a fresh one.
let edited = (scenario: Scenario.t, ~source1: MockSource.t) => {
  let sources =
    scenario.config.chainMap
    ->ChainMap.keys
    ->Array.map(chainId => {
      let chain = chainId->ChainId.toInt
      (chain, chain === 1 ? source1 : MockSource.make(Scenario.defaultMethods, ~chainId=chain))
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
  }> = await sql->Postgres.unsafe(
    `SELECT "id", "progress_block" FROM "${pgSchema}"."envio_chains" ORDER BY "id";`,
  )
  rows->Array.map(row => (row["id"]->ChainId.toString, row["progress_block"]))
}

let counterPartitions = async (indexer: IndexerRunner.t) => {
  let {sql, pgSchema} = indexer.pg
  let rows: array<{
    "name": string,
  }> = await sql->Postgres.unsafe(
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

let refusal = async (restart: unit => promise<IndexerRunner.t>) =>
  switch await restart() {
  | _ => "the restart to be refused, but it resumed"
  | exception JsExn(e) => e->JsExn.message->Option.getOr("an error without a message")
  | exception Persistence.StorageError({message}) => message
  }

let incompatible = (~paths) =>
  `The following config changes are incompatible with the existing indexer data:

${paths->Array.map(path => `    - ${path}`)->Array.join("\n")}

Pick one:
  1. Revert the changes above  # resume indexing where it left off
  2. envio dev -r              # delete all indexed data and start over
  3. Run a second indexer alongside this one — keep both datasets:
       ENVIO_PG_SCHEMA=<new_schema> \\
${switch IndexerRunner.selectedBackend {
    | #clickhouse => "       ENVIO_CLICKHOUSE_DATABASE=<new_db> \\\n"
    | #postgres => ""
    }}       ENVIO_INDEXER_PORT=<new_port> \\
       envio dev`

describe("envio start --chain with a chain the database doesn't have yet", () => {
  deployed->Scenario.it(
    "Adds the chain and indexes it, leaving the deployed chain as it was",
    ~sources=[{chain: 1}],
    async (~t, ~indexer, ~source) => {
      await catchUp(~indexer, ~source=source(1), ~items=[bump(1n)])

      let (config, sources) = withChain137->edited(~source1=source(1))
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
        ),
        ~message="Chain 137 gets a row, a partition and its config addresses, and indexes into them. Chain 1 keeps what it had",
      ).toEqual((
        [{id: "total", count: 1n, chainId: 1}, {id: "total", count: 10n, chainId: 137}],
        [("1", 100), ("137", 100)],
        ["Counter$1", "Counter$137"],
        [("1", "Token"), ("137", "Token")],
      ))
    },
  )

  deployed->Scenario.it(
    "Resumes another chain's process without adding the chain it doesn't drive",
    ~sources=[{chain: 1}],
    async (~t, ~indexer, ~source) => {
      await catchUp(~indexer, ~source=source(1), ~items=[bump(1n)])

      let (config, _) = withChain137->edited(~source1=source(1))
      let resumed = await indexer.restart(~config, ~chains=[ChainId.fromInt(1)], ())

      t.expect(
        (await chainRows(resumed), await counterPartitions(resumed)),
        ~message="Chain 137 is left for its own process to add",
      ).toEqual(([("1", 100)], ["Counter$1"]))
    },
  )

  deployed->Scenario.it(
    "Refuses a new chain in a run that doesn't name it with --chain",
    ~sources=[{chain: 1}],
    async (~t, ~indexer, ~source) => {
      await catchUp(~indexer, ~source=source(1), ~items=[])
      let (config, _) = withChain137->edited(~source1=source(1))

      t.expect(await refusal(() => indexer.restart(~config, ()))).toBe(
        incompatible(~paths=["evm.chains.137"]),
      )
    },
  )

  deployed->Scenario.it(
    "Refuses to add a chain alongside any other config change",
    ~sources=[{chain: 1}],
    async (~t, ~indexer, ~source) => {
      await catchUp(~indexer, ~source=source(1), ~items=[])

      let chains137 = [ChainId.fromInt(137)]
      let newContract = Scenario.make(
        ~schema,
        ~configYaml=configYaml(
          ~chains=[chainYaml(1), chainYaml(137, ~contract="Vault")],
          ~contracts=["Token", "Vault"],
        ),
      )
      let newEntity = Scenario.make(
        ~schema=schema ++ "\ntype Extra {\n  id: ID!\n}\n",
        ~configYaml=configYaml(~chains=[chainYaml(1), chainYaml(137)]),
      )
      let twoNewChains = Scenario.make(
        ~schema,
        ~configYaml=configYaml(~chains=[chainYaml(1), chainYaml(10), chainYaml(137)]),
      )

      let refused = async (scenario, ~chains) => {
        let (config, _) = scenario->edited(~source1=source(1))
        await refusal(() => indexer.restart(~config, ~chains, ()))
      }

      t.expect((
        await refused(newContract, ~chains=chains137),
        await refused(newEntity, ~chains=chains137),
        await refused(twoNewChains, ~chains=[ChainId.fromInt(10), ChainId.fromInt(137)]),
      )).toEqual((
        incompatible(~paths=["evm.contracts.Vault", "contracts"]),
        incompatible(~paths=["entities[1]"]),
        incompatible(~paths=["evm.chains.10", "evm.chains.137"]),
      ))
    },
  )
})
