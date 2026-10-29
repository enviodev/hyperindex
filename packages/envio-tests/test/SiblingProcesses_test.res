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
  await source.expectItemsQueries([
    {fromBlock: 1, toBlock: Bounded(300), reply: Respond({items: [writeItems(~chainId)]})},
  ])
  await source.expectItemsQueries([
    {fromBlock: 301, reply: Respond({items: [], latestFetchedBlockNumber: 500})},
  ])
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
      let chains =
        (await indexer.queryChains())->Array.map(
          chain => (chain.id->ChainId.toInt, chain.firstEventBlock, chain.readyAt->Option.isSome),
        )
      await indexer.usePostgresSql(
        async sql =>
          t.expect(
            (await sql->PgCatalog.indexes(~pgSchema=indexer.pgSchema))
            ->Array.filter(index => index.columns == ["owner"])
            ->Array.map(index => (index.tableName, index.isValid))
            ->Array.toSorted(((a, _), (b, _)) => String.compare(a, b)),
            ~message="Each built the owner index on its own chain's partition only",
          ).toEqual([("Item$1", true), ("Item$137", true)]),
      )
      // A ClickHouse read stops at the progress its own run knew of, so the rows
      // are read by a run resumed after both siblings — once nothing else is
      // left to read, since that run builds indexes of its own.
      let items: array<item> = await (await indexer.restart()).query("Item")

      t.expect((items->Array.length, chains)).toEqual((
        rowsPerSibling * 2,
        // Each sibling stamped its own chain and left the other's alone.
        [(1, Some(1), true), (137, Some(137), true)],
      ))
    },
  )
})
