open Vitest

// A rollback that leaves a sibling chain alone must leave it fetching. A fetch
// tick while the reorg is still being resolved, kicked by a contractRegister
// run ending then, must not hand out requests nothing will send.
let chainYaml = chainId =>
  `
  - id: ${chainId->Int.toString}
    rpc:
      url: https://rpc${chainId->Int.toString}.example.test
      for: sync
    start_block: 1
    max_reorg_depth: 1500
    contracts:
      - name: Gravatar
        address: "0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3"`

let scenario = Scenario.make(
  ~supervised=false,
  ~configYaml=`
name: sibling-fetch-after-rollback
rollback_on_reorg: true
disable_default_cross_chain: true
contracts:
  - name: Gravatar
    events:
      - event: "TestEvent()"
chains:${chainYaml(100)}${chainYaml(1337)}
`,
)

let methods = [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes]

type registerOps = {add: Address.t => unit}
type registerContext = {chain: {"Gravatar": registerOps}}

let heldRegister = (~blockNumber, ~gate: MockSource.Gate.t): MockSource.itemMock => {
  blockNumber,
  logIndex: 0,
  contractRegister: async args => {
    await gate.wait()
    let context = args.context->(Utils.magic: Internal.contractRegisterContext => registerContext)
    context.chain["Gravatar"].add(
      "0x0000000000000000000000000000000000000001"->Address.unsafeFromString,
    )
  },
}

describe("A sibling chain after an isolated rollback", () => {
  scenario->Scenario.it(
    "keeps fetching when a contractRegister run ended while the reorg was resolved",
    ~sources=[{chain: 100, methods}, {chain: 1337, methods}],
    async (~t, ~indexer, ~source) => {
      let source100 = source(100)
      let source1337 = source(1337)
      let gate = MockSource.Gate.make()
      let _ = await Promise.all2((
        Scenario.enterReorgThreshold(~indexer, ~source=source100, ~head=2000, ~preThresholdTo=499),
        Scenario.enterReorgThreshold(~indexer, ~source=source1337, ~head=2000, ~preThresholdTo=499),
      ))
      await source100.expectItemsQueries([{fromBlock: 500, reply: LeavePending}])
      await source1337.expectItemsQueries([
        {
          fromBlock: 500,
          reply: Respond({
            items: [heldRegister(~blockNumber=620, ~gate)],
            latestFetchedBlockNumber: 650,
          }),
        },
      ])
      // Real time: the held contractRegister runs off the clock.
      await Scenario.waitUntil(() => gate.entered.contents > 0, ~message="the contractRegister")
      await source1337.expectItemsQueries([
        {
          fromBlock: 651,
          reply: Respond({
            items: [],
            latestFetchedBlockNumber: 700,
            prevRangeLastBlock: {blockNumber: 650, blockHash: "0x650a"},
          }),
        },
      ])
      // The reorg dropped chain 100's query; its answer would be discarded.
      source100.drainPendingItemsQueries()
      // The run ends while the rollback is still finding its depth.
      gate.release()
      // Real time: the held contractRegister runs off the clock.
      await Scenario.waitUntil(
        () => !indexer.isRegisteringContracts(),
        ~message="the contractRegister run to end",
      )
      await source1337.expectBlockHashLookup({
        blockNumbers: [620],
        reply: [{blockNumber: 620, blockHash: "0x620", blockTimestamp: 620}],
      })
      await indexer.getRollbackReadyPromise()
      await source100.expectItemsQueries([{reply: LeavePending}])
      t.expect(source100.pendingItemsQueries->Array.map(query => query.fromBlock)).toEqual([500])
    },
  )
})
