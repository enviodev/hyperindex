open Vitest

// https://github.com/enviodev/hyperindex/issues/316
// A contract with an `end_block` is fetched up to that block and no further,
// while the rest of its chain keeps going.

let gravatar = "0x1111111111111111111111111111111111111111"

let scenario = Scenario.make(
  ~configYaml=`
name: contract-end-block
rollback_on_reorg: false
chains:
  - id: 1337
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 1
    max_reorg_depth: 0
    contracts:
      - name: Gravatar
        address: "${gravatar}"
        end_block: 50
        events:
          - event: "TestEvent()"
      - name: Wild
        events:
          - event: "Ping()"
`,
  ~schema=`
type Seen {
  id: ID!
}
`,
  ~handlers=`
import { indexer } from "envio";

indexer.onEvent({ contract: "Gravatar", event: "TestEvent" }, async ({ event, context }) => {
  context.Seen.set({ id: \`\${event.block.number}\` });
});
indexer.onEvent({ contract: "Wild", event: "Ping", wildcard: true }, async () => {});
`,
)

type seen = {id: string}

let gravatarEvent = (~blockNumber): MockSource.itemMock => {
  event: "Gravatar.TestEvent",
  blockNumber,
  logIndex: 0,
  srcAddress: gravatar,
}

describe("A contract with an end block", () => {
  scenario->Scenario.it(
    "is fetched no further than its end block",
    ~sources=[{chain: 1337}],
    async (~t, ~indexer, ~source) => {
      let sync = source(1337)
      sync.resolveGetHeightOrThrow(1000)
      await sync.expectItemsQueries([
        {
          address: gravatar,
          fromBlock: 1,
          toBlock: Bounded(50),
          reply: Respond({items: [gravatarEvent(~blockNumber=40)], latestFetchedBlockNumber: 50}),
        },
        {
          where: query => query->MockSource.addresses->Array.length == 0,
          fromBlock: 1,
          reply: Respond({items: [], latestFetchedBlockNumber: 1000}),
        },
      ])
      sync.resolveGetHeightOrThrow(1100)
      await sync.expectItemsQueries([{fromBlock: 1001, reply: LeavePending}])
      await indexer.getBatchWritePromise()
      let rows: array<seen> = await indexer.query("Seen")
      t.expect((
        sync.pendingItemsQueries->Array.map(query => query->MockSource.addresses),
        rows->Array.map(row => row.id),
      )).toEqual(([[]], ["40"]))
    },
  )

  scenario->Scenario.it(
    "handles none of its events past the end block that a head request brings back",
    ~sources=[{chain: 1337}],
    async (~t, ~indexer, ~source) => {
      let sync = source(1337)
      sync.resolveGetHeightOrThrow(100)
      await sync.expectItemsQueries([
        {
          fromBlock: 1,
          reply: Respond({
            items: [gravatarEvent(~blockNumber=40), gravatarEvent(~blockNumber=60)],
            latestFetchedBlockNumber: 100,
          }),
        },
      ])
      await indexer.getBatchWritePromise()
      let rows: array<seen> = await indexer.query("Seen")
      t.expect(rows->Array.map(row => row.id)).toEqual(["40"])
    },
  )
})

let factory = "0x2222222222222222222222222222222222222222"

let dynamicScenario = Scenario.make(
  ~configYaml=`
name: contract-end-block-dynamic
rollback_on_reorg: false
chains:
  - id: 1337
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 1
    max_reorg_depth: 0
    contracts:
      - name: Factory
        address: "${factory}"
        events:
          - event: "Created()"
      - name: Child
        end_block: 50
        events:
          - event: "Ping()"
`,
  ~handlers=`
import { indexer } from "envio";

indexer.contractRegister({ contract: "Factory", event: "Created" }, async ({ context }) => {
  context.chain.Child.add("0x0000000000000000000000000000000000000001");
});
indexer.onEvent({ contract: "Child", event: "Ping" }, async () => {});
`,
)

let childCreatedAt = (~blockNumber): MockSource.itemMock => {
  event: "Factory.Created",
  blockNumber,
  logIndex: 0,
  srcAddress: factory,
}

describe("A dynamic contract with an end block", () => {
  dynamicScenario->Scenario.it(
    "fetched to its end block before the chain nears the head is not asked for again there",
    ~sources=[{chain: 1337}],
    async (~t, ~indexer as _, ~source) => {
      let sync = source(1337)
      sync.resolveGetHeightOrThrow(1000)
      await sync.expectItemsQueries([
        {
          fromBlock: 1,
          reply: Respond({items: [childCreatedAt(~blockNumber=10)], latestFetchedBlockNumber: 900}),
        },
      ])
      // The child is fetched to its end block while the factory's next query
      // is open-ended; that response brings the head close.
      await sync.expectItemsQueries([
        {
          fromBlock: 10,
          reply: Respond({items: [], latestFetchedBlockNumber: 50, knownHeight: 1100}),
        },
        {fromBlock: 901, reply: LeavePending},
      ])
      await sync.expectItemsQueries([
        {fromBlock: 901, reply: Respond({items: [], latestFetchedBlockNumber: 1100})},
      ])
      sync.resolveGetHeightOrThrow(1200)
      await sync.expectItemsQueries([{reply: LeavePending}])
      t.expect(sync.pendingItemsQueries->Array.map(query => query.fromBlock)).toEqual([1101])
    },
  )
})

let wildcardScenario = Scenario.make(
  ~configYaml=`
name: contract-end-block-wildcard
rollback_on_reorg: false
chains:
  - id: 1337
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 1
    max_reorg_depth: 0
    contracts:
      - name: Gravatar
        address: "${gravatar}"
        events:
          - event: "TestEvent()"
      - name: Wild
        end_block: 50
        events:
          - event: "Ping()"
`,
  ~handlers=`
import { indexer } from "envio";

indexer.onEvent({ contract: "Gravatar", event: "TestEvent" }, async () => {});
indexer.onEvent({ contract: "Wild", event: "Ping", wildcard: true }, async () => {});
`,
)

describe("A wildcard contract with an end block", () => {
  wildcardScenario->Scenario.it(
    "is fetched no further than its end block",
    ~sources=[{chain: 1337}],
    async (~t, ~indexer as _, ~source) => {
      let sync = source(1337)
      sync.resolveGetHeightOrThrow(1000)
      await sync.expectItemsQueries([
        {address: gravatar, reply: LeavePending},
        {where: query => query->MockSource.addresses == [], reply: LeavePending},
      ])
      t.expect(
        sync.pendingItemsQueries
        ->Array.filter(query => query->MockSource.addresses == [])
        ->Array.map(query => (query.fromBlock, query.toBlock)),
      ).toEqual([(1, Bounded(50))])
    },
  )
})
