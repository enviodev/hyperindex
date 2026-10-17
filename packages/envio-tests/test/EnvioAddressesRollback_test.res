open Vitest

// https://github.com/enviodev/hyperindex/issues/1187
// An address can be registered for two contracts, one row each. A reorg that
// undoes only the later registration removes only that row: the earlier one,
// below the rollback target, has to survive under the same address.

let scenario = Scenario.make(
  ~configYaml=`
name: envio-addresses-rollback
rollback_on_reorg: true
chains:
  - id: 1
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 1
    max_reorg_depth: 200
    contracts:
      - name: Gravatar
        address: "0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3"
        events:
          - event: "TestEvent(address[] addresses)"
      - name: NftFactory
        address: "0x3B2f78c5BF6D9C12Ee1225D5F374aa91204580c4"
        events:
          - event: "SimpleNftCreated(address[] addresses)"
`,
  ~schema=`
type Gravatar {
  id: ID!
  owner: String!
}
`,
  ~handlers=`
import { indexer } from "envio";

indexer.onEvent({ contract: "Gravatar", event: "TestEvent" }, async () => {});
indexer.onEvent({ contract: "NftFactory", event: "SimpleNftCreated" }, async () => {});

indexer.contractRegister({ contract: "Gravatar", event: "TestEvent" }, async ({ event, context }) => {
  for (const address of event.params.addresses) {
    context.chain.Gravatar.add(address);
  }
});
indexer.contractRegister(
  { contract: "NftFactory", event: "SimpleNftCreated" },
  async ({ event, context }) => {
    for (const address of event.params.addresses) {
      context.chain.NftFactory.add(address);
    }
  },
);
`,
)

let shared = "0x1111111111111111111111111111111111111111"->Address.Evm.fromStringOrThrow
let late = "0x2222222222222222222222222222222222222222"->Address.Evm.fromStringOrThrow

let registering = (~blockNumber, ~event, addresses: array<Address.t>): MockSource.itemMock => {
  event,
  blockNumber,
  logIndex: 0,
  params: dict{"addresses": addresses->(Utils.magic: array<Address.t> => unknown)},
}

let registered = (indexer: IndexerRunner.t) =>
  indexer.queryAddresses()->Promise.thenResolve(rows =>
    rows
    ->Array.filter(row => row.registrationBlock !== -1)
    ->Array.map(row => (row.address, row.contractName, row.registrationBlock))
    ->Array.toSorted((a, b) => {
      let key = ((address, contract, block)) =>
        `${block->Int.toString->String.padStart(10, "0")} ${contract} ${address->Address.toString}`
      String.compare(key(a), key(b))
    })
  )

describe("A rollback of an address registration", () => {
  scenario->Scenario.it(
    "removes only the registrations after the target, by contract",
    ~sources=[{chain: 1, methods: [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes]}],
    async (~t, ~indexer, ~source) => {
      let source = source(1)
      source.resolveGetHeightOrThrow(300)
      await source.expectItemsQueries([
        {
          partitionId: "0",
          fromBlock: 1,
          toBlock: Bounded(100),
          reply: Respond({
            items: [registering(~blockNumber=50, ~event="Gravatar.TestEvent", [shared])],
          }),
        },
      ])
      await indexer.getBatchWritePromise()
      await source.expectItemsQueries([
        // The registered address catches up to the config's addresses.
        {
          partitionId: "2",
          fromBlock: 50,
          reply: Respond({items: [], latestFetchedBlockNumber: 100}),
        },
        {
          // The partition the config's addresses are fetched in.
          partitionId: "0",
          fromBlock: 101,
          reply: Respond({
            items: [
              registering(~blockNumber=200, ~event="NftFactory.SimpleNftCreated", [shared, late]),
            ],
            latestFetchedBlockNumber: 300,
          }),
        },
      ])
      await indexer.getBatchWritePromise()
      await source.expectItemsQueries([
        {
          partitionId: "2",
          fromBlock: 101,
          reply: Respond({items: [], latestFetchedBlockNumber: 300}),
        },
        {
          partitionId: "3",
          fromBlock: 200,
          reply: Respond({items: [], latestFetchedBlockNumber: 300}),
        },
      ])
      await indexer.waitUntilIdle()
      let beforeReorg = await registered(indexer)

      await Scenario.reorgAbove(~indexer, ~source, ~head=300, ~validUpTo=100)

      t.expect((beforeReorg, await registered(indexer))).toEqual((
        [(shared, "Gravatar", 50), (shared, "NftFactory", 200), (late, "NftFactory", 200)],
        [(shared, "Gravatar", 50)],
      ))
    },
  )
})

describe("An address registered again for the same contract", () => {
  scenario->Scenario.it(
    "is stored once, at the block it was first registered",
    ~sources=[{chain: 1, methods: [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes]}],
    async (~t, ~indexer, ~source) => {
      let source = source(1)
      source.resolveGetHeightOrThrow(300)
      await source.expectItemsQueries([
        {
          partitionId: "0",
          fromBlock: 1,
          toBlock: Bounded(100),
          reply: Respond({
            items: [registering(~blockNumber=50, ~event="Gravatar.TestEvent", [shared, shared])],
          }),
        },
      ])
      await indexer.getBatchWritePromise()
      await source.expectItemsQueries([
        {
          partitionId: "2",
          fromBlock: 50,
          reply: Respond({items: [], latestFetchedBlockNumber: 100}),
        },
        {
          partitionId: "0",
          fromBlock: 101,
          reply: Respond({
            items: [registering(~blockNumber=200, ~event="Gravatar.TestEvent", [shared])],
            latestFetchedBlockNumber: 300,
          }),
        },
      ])
      await indexer.getBatchWritePromise()
      await source.expectItemsQueries([
        {
          partitionId: "2",
          fromBlock: 101,
          reply: Respond({items: [], latestFetchedBlockNumber: 300}),
        },
      ])
      await indexer.waitUntilIdle()

      t.expect(await registered(indexer)).toEqual([(shared, "Gravatar", 50)])
    },
  )
})
