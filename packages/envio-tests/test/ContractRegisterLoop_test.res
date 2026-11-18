open Vitest

// contractRegister runs in its own loop over the chain buffer, not inside the
// response that delivered its event.
let scenario = Scenario.make(
  ~configYaml=`
name: contract-register-loop
rollback_on_reorg: true
contracts:
  - name: Gravatar
    events:
      - event: "TestEvent()"
chains:
  - id: 1337
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 1
    max_reorg_depth: 1500
    contracts:
      - name: Gravatar
        address: "0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3"
`,
)

let methods = [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes]

let address = n => `0x${n->Int.toString->String.padStart(40, "0")}`->Address.unsafeFromString

type registerOps = {add: Address.t => unit}
type registerContext = {chain: {"Gravatar": registerOps}}

let heldRegister = (~blockNumber, ~gate: MockSource.Gate.t, addresses): MockSource.itemMock => {
  blockNumber,
  logIndex: 0,
  contractRegister: async args => {
    await gate.wait()
    let context = args.context->(Utils.magic: Internal.contractRegisterContext => registerContext)
    addresses->Array.forEach(address => context.chain["Gravatar"].add(address))
  },
}

let dynamicAddresses = async (indexer: IndexerRunner.t) =>
  (await indexer.queryAddresses())
  ->Array.filter(row => row.registrationBlock !== -1)
  ->Array.map(row => (row.address->Address.toString, row.registrationBlock))

describe("contractRegister loop", () => {
  scenario->Scenario.it(
    "does not hold back the next query of the partition that delivered the event",
    ~sources=[{chain: 1337, methods}],
    async (~t, ~indexer as _, ~source) => {
      let sourceMock = source(1337)
      let gate = MockSource.Gate.make()
      sourceMock.resolveGetHeightOrThrow(2000)
      await sourceMock.expectItemsQueries([
        {
          partitionId: "0",
          fromBlock: 1,
          reply: Respond({
            items: [heldRegister(~blockNumber=3, ~gate, [address(1)])],
            latestFetchedBlockNumber: 5,
          }),
        },
      ])
      // Real time: the held contractRegister runs off the clock.
      await Scenario.waitUntil(() => gate.entered.contents > 0, ~message="the contractRegister")
      let pendingWhileHeld =
        sourceMock.pendingItemsQueries->Array.map(query => (query.partitionId, query.fromBlock))
      gate.release()
      t.expect(pendingWhileHeld).toEqual([("0", 6)])
    },
  )

  scenario->Scenario.it(
    "registers nothing from a contractRegister a rollback overtook",
    ~sources=[{chain: 1337, methods}],
    async (~t, ~indexer, ~source) => {
      let sourceMock = source(1337)
      let gate = MockSource.Gate.make()
      sourceMock.resolveGetHeightOrThrow(2000)
      await sourceMock.expectItemsQueries([
        {
          partitionId: "0",
          fromBlock: 1,
          reply: Respond({items: [], latestFetchedBlockNumber: 499}),
        },
      ])
      await sourceMock.expectItemsQueries([
        {
          partitionId: "0",
          fromBlock: 500,
          reply: Respond({
            items: [heldRegister(~blockNumber=620, ~gate, [address(1)])],
            latestFetchedBlockNumber: 650,
          }),
        },
      ])
      // Real time: the held contractRegister runs off the clock.
      await Scenario.waitUntil(() => gate.entered.contents > 0, ~message="the contractRegister")
      await sourceMock.expectItemsQueries([
        {
          partitionId: "0",
          fromBlock: 651,
          reply: Respond({
            items: [],
            latestFetchedBlockNumber: 700,
            prevRangeLastBlock: {blockNumber: 650, blockHash: "0x650a"},
          }),
        },
      ])
      await sourceMock.expectBlockHashLookup({
        blockNumbers: [499, 620],
        reply: [
          {blockNumber: 499, blockHash: "0x499", blockTimestamp: 499},
          {blockNumber: 620, blockHash: "0x620a", blockTimestamp: 620},
        ],
      })
      await indexer.getRollbackReadyPromise()
      gate.release()
      sourceMock.drainPendingItemsQueries()
      await indexer.waitUntilIdle()
      t.expect(await dynamicAddresses(indexer)).toEqual([])
    },
  )
})
