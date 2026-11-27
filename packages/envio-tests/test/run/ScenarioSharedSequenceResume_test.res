open Vitest

// Under one checkpoint sequence shared by every chain, a chain idle since an
// early batch resumes at a checkpoint far below its sibling's. The resume trim
// has to start above the highest committed checkpoint: trimming at the idle
// chain's would delete rows the sibling committed after it.

let chainYaml = chainId =>
  `
  - id: ${chainId->Int.toString}
    rpc:
      url: https://rpc${chainId->Int.toString}.example.test
      for: sync
    start_block: 0
    contracts:
      - name: Token
        address: "0x0000000000000000000000000000000000000001"`

let scenario = Scenario.make(
  ~configYaml=`
name: shared-sequence-resume
contracts:
  - name: Token
    events:
      - event: Transfer(address indexed from, address indexed to, uint256 value)
chains:${chainYaml(1)}${chainYaml(137)}
`,
  ~schema=`
type Entity {
  id: ID!
  value: String!
}
`,
)

type entity = {id: string, value: string}
type entityOps = {set: entity => unit}
type entityContext = {@as("Entity") entity: entityOps}

let setEntity = (~id) =>
  async (args: Internal.handlerArgs) => {
    let context = args.context->(Utils.magic: Internal.handlerContext => entityContext)
    context.entity.set({id, value: id})
  }

let feed = async (indexer: IndexerRunner.t, ~source: MockSource.t, ~blockNumber, ~id) => {
  await source.expectItemsQueries([
    {
      coversBlock: blockNumber,
      reply: Respond({
        items: [{blockNumber, logIndex: 0, handler: setEntity(~id)}],
        latestFetchedBlockNumber: blockNumber,
      }),
    },
  ])
  await indexer.getBatchWritePromise()
}

describe("Resume under a checkpoint sequence shared across chains", () => {
  scenario->Scenario.it(
    "keeps a sibling's rows committed after an idle chain's last checkpoint",
    ~sources=[{chain: 1}, {chain: 137}],
    async (~t, ~indexer, ~source) => {
      source(1).resolveGetHeightOrThrow(100000)
      source(137).resolveGetHeightOrThrow(100000)
      await feed(indexer, ~source=source(1), ~blockNumber=5, ~id="A")
      await feed(indexer, ~source=source(137), ~blockNumber=8, ~id="B")

      let resumed = await indexer.restart()
      let entities: array<entity> = await resumed.query("Entity")
      t.expect(entities->Array.toSorted((a, b) => String.compare(a.id, b.id))).toEqual([
        {id: "A", value: "A"},
        {id: "B", value: "B"},
      ])
    },
  )
})
