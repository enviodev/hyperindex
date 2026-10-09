open Vitest

// Two `envio start --chain` processes driving different chains of one schema:
// a process each, so a connection pool each, contending on the same tables at
// once. Each resumes, writes its chain's rows, stamps its chain's metadata and,
// caught up, builds the indexes the schema promises on its own chain's rows.

let chainYaml = chainId =>
  `
  - id: ${chainId->Int.toString}
    rpc:
      url: https://rpc${chainId->Int.toString}.example.test
      for: sync
    start_block: 1
    contracts:
      - name: Gravatar
        address: "0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3"
`

let scenario = Scenario.make(
  ~supervised=false,
  ~configYaml=`
name: sibling-processes
disable_default_cross_chain: true
contracts:
  - name: Gravatar
    events:
      - event: "TestEvent()"
chains:${chainYaml(1)}${chainYaml(137)}`,
  ~schema=`
type Item {
  id: ID!
  owner: String! @index
}
`,
)

let rowsPerSibling = 200

type item = {id: string, owner: string}
type itemOps = {set: item => unit}
type handlerContext = {@as("Item") item: itemOps}

let writeItems = (~chainId): MockSource.itemMock => {
  blockNumber: chainId,
  logIndex: 0,
  handler: async args => {
    let context = args.context->(Utils.magic: Internal.handlerContext => handlerContext)
    for index in 0 to rowsPerSibling - 1 {
      context.item.set({
        id: `${chainId->Int.toString}-${index->Int.toString}`,
        owner: `owner-${mod(index, 5)->Int.toString}`,
      })
    }
  },
}

let catchUp = async (sibling: IndexerRunner.t, ~source: MockSource.t, ~chainId) => {
  source.resolveGetHeightOrThrow(500)
  source.resolveGetItemsOrThrow([writeItems(~chainId)], ~latestFetchedBlockNumber=500)
  await sibling.waitUntilReady()
}

describe("Two processes indexing one schema", () => {
  scenario->Scenario.it(
    "each resume, write and build indexes without standing on the other",
    ~sources=[{chain: 1}, {chain: 137}],
    async (~t, ~indexer, ~source) => {
      // The run that created the schema hands over to the two siblings.
      await indexer.stop()
      let (first, second) = await Promise.all2((
        indexer.sibling(~chains=[ChainId.fromInt(1)]),
        indexer.sibling(~chains=[ChainId.fromInt(137)]),
      ))
      let _ = await Promise.all2((
        first->catchUp(~source=source(1), ~chainId=1),
        second->catchUp(~source=source(137), ~chainId=137),
      ))

      // Chain metadata goes out on a throttle of its own; stopping flushes it.
      let _ = await Promise.all2((first.stop(), second.stop()))
      let {sql, pgSchema} = indexer.pg
      let items: array<item> = await indexer.query("Item")
      let chains: array<{
        "id": int,
        "first_event_block": Null.t<int>,
        "ready": bool,
      }> = await sql->Sql.queryForTests(
        `SELECT "id", "first_event_block", "ready_at" IS NOT NULL AS "ready" FROM "${pgSchema}"."envio_chains" ORDER BY "id";`,
      )

      t.expect((
        items->Array.length,
        chains->Array.map(
          chain => (chain["id"], chain["first_event_block"]->Null.toOption, chain["ready"]),
        ),
        (await sql->PgCatalog.indexes(~pgSchema))
        ->Array.filter(index => index.columns == ["owner"])
        ->Array.map(index => (index.tableName, index.isValid))
        ->Array.toSorted(((a, _), (b, _)) => String.compare(a, b)),
      )).toEqual((
        rowsPerSibling * 2,
        // Each sibling stamped its own chain and left the other's alone.
        [(1, Some(1), true), (137, Some(137), true)],
        // Each built the owner index on its own chain's partition only.
        [("Item$1", true), ("Item$137", true)],
      ))
    },
  )
})
