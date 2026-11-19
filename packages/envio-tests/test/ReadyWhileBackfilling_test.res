open Vitest

let scenario = Scenario.make(
  ~supervised=false,
  ~configYaml=`
name: ready-while-backfilling
rollback_on_reorg: false
contracts:
  - name: Token
    events:
      - event: Transfer()
chains:
  - id: 1
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 1
    max_reorg_depth: 0
    contracts:
      - name: Token
        address: "0x0000000000000000000000000000000000000001"
  - id: 2
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 1
    max_reorg_depth: 0
    contracts:
      - name: Token
        address: "0x0000000000000000000000000000000000000001"
`,
)

describe("Readiness across chains", () => {
  scenario->Scenario.it(
    "isn't reached by one chain processing to its head while another is still backfilling",
    ~sources=[{chain: 1}, {chain: 2}],
    async (~t, ~indexer, ~source) => {
      let atHead = source(1)
      let backfilling = source(2)
      atHead.resolveGetHeightOrThrow(100)
      backfilling.resolveGetHeightOrThrow(100)
      await backfilling.expectItemsQueries([{fromBlock: 1, reply: LeavePending}])
      await atHead.expectItemsQueries([
        {
          fromBlock: 1,
          reply: Respond({items: [{blockNumber: 50, logIndex: 0}], latestFetchedBlockNumber: 100}),
        },
      ])
      await indexer.getBatchWritePromise()
      await indexer.waitUntilIdle()

      t.expect(
        (await indexer.queryChains())->Array.map(chain => (chain.id->ChainId.toInt, chain.readyAt)),
      ).toEqual([(1, None), (2, None)])
    },
  )
})
