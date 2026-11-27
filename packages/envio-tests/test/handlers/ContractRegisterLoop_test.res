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

let pendingFromBlocks = (sourceMock: MockSource.t) =>
  sourceMock.pendingItemsQueries->Array.map(query => query.fromBlock)

let dynamicAddresses = async (indexer: IndexerRunner.t) =>
  (await indexer.queryAddresses())
  ->Array.filter(row => row.registrationBlock !== -1)
  ->Array.map(row => (row.address->Address.toString, row.registrationBlock))

describe("contractRegister loop", () => {
  scenario->Scenario.it(
    "does not hold back the next query of the request that delivered the event",
    ~sources=[{chain: 1337, methods}],
    async (~t, ~indexer as _, ~source) => {
      let sourceMock = source(1337)
      let gate = MockSource.Gate.make()
      sourceMock.resolveGetHeightOrThrow(2000)
      await sourceMock.expectItemsQueries([
        {
          fromBlock: 1,
          reply: Respond({
            items: [heldRegister(~blockNumber=3, ~gate, [address(1)])],
            latestFetchedBlockNumber: 5,
          }),
        },
      ])
      // Real time: the held contractRegister runs off the clock.
      await Scenario.waitUntil(() => gate.entered.contents > 0, ~message="the contractRegister")
      let pendingWhileHeld = sourceMock->pendingFromBlocks
      gate.release()
      t.expect(pendingWhileHeld).toEqual([6])
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
          fromBlock: 1,
          reply: Respond({items: [], latestFetchedBlockNumber: 499}),
        },
      ])
      await sourceMock.expectItemsQueries([
        {
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
          fromBlock: 651,
          reply: Respond({
            items: [],
            latestFetchedBlockNumber: 700,
            prevRangeLastBlock: {blockNumber: 650, blockHash: "0x650a"},
          }),
        },
      ])
      await sourceMock.expectBlockHashLookup({
        blockNumbers: [620],
        reply: [{blockNumber: 620, blockHash: "0x620a", blockTimestamp: 620}],
      })
      await indexer.getRollbackReadyPromise()
      gate.release()
      sourceMock.drainPendingItemsQueries()
      await indexer.waitUntilIdle()
      t.expect(await dynamicAddresses(indexer)).toEqual([])
    },
  )

  scenario->Scenario.it(
    "runs the backlog a rollback kept after dropping the run that overlapped it",
    ~sources=[{chain: 1337, methods}],
    async (~t, ~indexer, ~source) => {
      let sourceMock = source(1337)
      let gate = MockSource.Gate.make()
      sourceMock.resolveGetHeightOrThrow(2000)
      await sourceMock.expectItemsQueries([
        {
          fromBlock: 1,
          reply: Respond({items: [], latestFetchedBlockNumber: 499}),
        },
      ])
      // One run reads both blocks; the rollback keeps 550 and drops 620.
      await sourceMock.expectItemsQueries([
        {
          fromBlock: 500,
          reply: Respond({
            items: [
              heldRegister(~blockNumber=550, ~gate, [address(1)]),
              heldRegister(~blockNumber=620, ~gate, [address(2)]),
            ],
            latestFetchedBlockNumber: 650,
          }),
        },
      ])
      // Real time: the held contractRegister runs off the clock.
      await Scenario.waitUntil(() => gate.entered.contents > 1, ~message="the contractRegister")
      await sourceMock.expectItemsQueries([
        {
          fromBlock: 651,
          reply: Respond({
            items: [],
            latestFetchedBlockNumber: 700,
            prevRangeLastBlock: {blockNumber: 650, blockHash: "0x650a"},
          }),
        },
      ])
      // The run ends while the rollback is still finding its depth, so it is
      // dropped, and the rollback keeps 550 in the backlog.
      gate.release()
      // Real time: the held contractRegister runs off the clock.
      await Scenario.waitUntil(
        () => !indexer.isRegisteringContracts(),
        ~message="the contractRegister run to end",
      )
      await sourceMock.expectBlockHashLookup({
        blockNumbers: [550, 620],
        reply: [
          {blockNumber: 550, blockHash: "0x550", blockTimestamp: 550},
          {blockNumber: 620, blockHash: "0x620a", blockTimestamp: 620},
        ],
      })
      await indexer.getRollbackReadyPromise()
      sourceMock.drainPendingItemsQueries()
      await sourceMock.expectItemsQueries([{reply: LeavePending}, {reply: LeavePending}])
      t.expect(
        sourceMock.pendingItemsQueries->Array.map(
          query => (
            query.fromBlock,
            query.toBlock,
            query->MockSource.addresses->Array.map(Address.toString),
          ),
        ),
        ~message="550's registration is fetched, from its block and in the group; 620's is not",
      ).toEqual([
        (550, Bounded(551), [address(1)->Address.toString]),
        (
          552,
          Unbounded,
          ["0x2b2f78c5bf6d9c12ee1225d5f374aa91204580c3", address(1)->Address.toString],
        ),
      ])
    },
  )
})
