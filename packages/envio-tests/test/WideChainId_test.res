open Vitest

// A chain id past int32 widens every chain-id column and every parameter cast
// for one to BIGINT. A column or cast left behind refuses the id the first time
// it is written or read, so the whole loop runs on one: a write, a reorg that
// rolls it back, and a restart that resumes from what is stored.

let chainId = 2494104990.

let scenario = Scenario.make(
  ~configYaml=`
name: wide-chain-id
rollback_on_reorg: true
chains:
  - id: ${chainId->Float.toString}
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 1
    max_reorg_depth: 200
    contracts:
      - name: Token
        address: "0x0000000000000000000000000000000000000001"
        events:
          - event: Transfer(address indexed from, address indexed to, uint256 value)
`,
  ~schema=`
type Tally {
  id: ID!
  count: Int!
}
`,
)

type tally = {id: string, count: int}
type tallyOps = {set: tally => unit}
type handlerContext = {@as("Tally") tally: tallyOps}

let setTally = (~block, ~count): MockSource.itemMock => {
  blockNumber: block,
  logIndex: 0,
  handler: async args =>
    (args.context->(Utils.magic: Internal.handlerContext => handlerContext)).tally.set({
      id: "tally",
      count,
    }),
}

let methods: array<MockSource.method> = [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes]

describe("A chain id past int32", () => {
  scenario->Scenario.it(
    "is written, rolled back and resumed",
    ~sources=[{chain: chainId->(Utils.magic: float => int), methods}],
    async (~t, ~indexer, ~source) => {
      let source = source(chainId->(Utils.magic: float => int))
      source.resolveGetHeightOrThrow(300)
      await Utils.delay(0)
      await Utils.delay(0)
      await MockSource.waitItemsQuery(source)
      source.resolveGetItemsOrThrow([setTally(~block=50, ~count=1)], ~latestFetchedBlockNumber=100)
      await indexer.getBatchWritePromise()
      await MockSource.waitItemsQuery(source)
      source.resolveGetItemsOrThrow([setTally(~block=200, ~count=2)], ~latestFetchedBlockNumber=300)
      await indexer.getBatchWritePromise()

      await Scenario.reorgAbove(~indexer, ~source, ~head=300, ~validUpTo=100)
      let rolledBack: array<tally> = await indexer.query("Tally")

      source.setAutoHeight(400)
      let restarted = await indexer.restart()
      let {sql, pgSchema} = restarted.pg
      let chains: array<{
        "id": string,
      }> = await sql->Sql.query(`SELECT "id"::text AS "id" FROM "${pgSchema}"."envio_chains";`)

      t.expect((rolledBack, chains)).toEqual((
        [{id: "tally", count: 1}],
        [{"id": chainId->Float.toString}],
      ))
    },
  )
})
