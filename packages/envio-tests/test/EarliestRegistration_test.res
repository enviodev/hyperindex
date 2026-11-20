open Vitest

let factory = "0xfafafafafafafafafafafafafafafafafafafafa"
let child = "0x00000000000000000000000000000000000000c1"
let other = "0x00000000000000000000000000000000000000c2"
let hub = "0x00000000000000000000000000000000000000b1"

// `Factory` points at a child, and the child announces its own birth through
// the wildcard `Created.Born`. Either registers the child, from different
// partitions, so they can arrive in any order. `Factory` can also open a `Hub`,
// a dynamic factory of children.
let configYaml = (~childOptions) =>
  `
name: earliest-registration
rollback_on_reorg: true
chains:
  - id: 1337
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 0
    max_reorg_depth: 200
    contracts:
      - name: Factory
        address: "${factory}"
        events:
          - event: "Pointed(address child)"
          - event: "Spawned(address child)"
          - event: "Opened(address hub)"
      - name: Hub
        events:
          - event: "Made(address child)"
      - name: Created
        events:
          - event: "Born()"
      - name: Child${childOptions}
        events:
          - event: "Ping()"
`

let schema = `
type Ping {
  id: ID!
  block: Int!
  handled: Int!
}
`

let handlers = `
import { indexer } from "envio";

indexer.contractRegister({ contract: "Factory", event: "Pointed" }, async ({ event, context }) => {
  context.chain.Child.add(event.params.child);
});
indexer.contractRegister({ contract: "Factory", event: "Spawned" }, async ({ event, context }) => {
  // Resolves after a \`Pointed\` handler of the same run, so a run holding both
  // collects the later block's registration first.
  for (let hop = 0; hop < 5; hop++) await Promise.resolve();
  context.chain.Child.add(event.params.child);
});
indexer.contractRegister({ contract: "Factory", event: "Opened" }, async ({ event, context }) => {
  context.chain.Hub.add(event.params.hub);
});
indexer.contractRegister({ contract: "Hub", event: "Made" }, async ({ event, context }) => {
  context.chain.Child.add(event.params.child);
});
indexer.contractRegister(
  { contract: "Created", event: "Born", wildcard: true },
  async ({ event, context }) => {
    context.chain.Child.add(event.srcAddress);
  },
);

indexer.onEvent({ contract: "Child", event: "Ping" }, async ({ event, context }) => {
  const id = \`\${event.block.number}-\${event.logIndex}\`;
  const seen = await context.Ping.get(id);
  context.Ping.set({ id, block: event.block.number, handled: (seen?.handled ?? 0) + 1 });
});
`

let scenario = Scenario.make(~configYaml=configYaml(~childOptions=""), ~schema, ~handlers)

// `Child` starts at block 200, so every registration below it is effective
// from 200.
let lateStartScenario = Scenario.make(
  ~configYaml=configYaml(~childOptions="\n        start_block: 200"),
  ~schema,
  ~handlers,
)

let sources: array<Scenario.sourceMock> = [{chain: 1337, autoHeight: 1000}]

let pointed = (~blockNumber, ~logIndex=0, address): MockSource.itemMock => {
  event: "Factory.Pointed",
  blockNumber,
  logIndex,
  srcAddress: factory,
  params: dict{"child": address->(Utils.magic: string => unknown)},
}

let spawned = (~blockNumber, ~logIndex=0, address): MockSource.itemMock => {
  ...pointed(~blockNumber, ~logIndex, address),
  event: "Factory.Spawned",
}

let opened = (~blockNumber, ~logIndex=0, address): MockSource.itemMock => {
  event: "Factory.Opened",
  blockNumber,
  logIndex,
  srcAddress: factory,
  params: dict{"hub": address->(Utils.magic: string => unknown)},
}

let made = (~blockNumber, ~logIndex=0, address): MockSource.itemMock => {
  event: "Hub.Made",
  blockNumber,
  logIndex,
  srcAddress: hub,
  params: dict{"child": address->(Utils.magic: string => unknown)},
}

let born = (~blockNumber, ~logIndex=0, address): MockSource.itemMock => {
  event: "Created.Born",
  blockNumber,
  logIndex,
  srcAddress: address,
  params: dict{},
}

let ping = (~blockNumber, ~logIndex=1, address): MockSource.itemMock => {
  event: "Child.Ping",
  blockNumber,
  logIndex,
  srcAddress: address,
  params: dict{},
}

// A block once per time its ping was handled.
let pingedBlocks = async (indexer: IndexerRunner.t) =>
  (await indexer.query("Ping"))
  ->Array.flatMap((ping: {"block": int, "handled": int}) =>
    Array.make(~length=ping["handled"], ping["block"])
  )
  ->Array.toSorted(Int.compare)

// A ping's id once per time it was handled.
let handledPingIds = async (indexer: IndexerRunner.t) =>
  (await indexer.query("Ping"))
  ->Array.flatMap((ping: {"id": string, "handled": int}) =>
    Array.make(~length=ping["handled"], ping["id"])
  )
  ->Array.toSorted(String.compare)

let registeredChildren = async (indexer: IndexerRunner.t) =>
  (await indexer.queryAddresses())
  ->Array.filter(row => row.contractName === "Child")
  ->Array.map(row => (row.address->Address.toString->String.toLowerCase, row.registrationBlock))
  ->Array.toSorted(((a, _), (b, _)) => String.compare(a, b))

let isFetchingFor = (address, query) =>
  query->MockSource.addresses->Array.some(queried => queried->Address.toString === address)

let isAddressFree = query => !(query->MockSource.selection).dependsOnAddresses

// The factory's first response points at `child` from block 50 while the
// wildcard partition, which holds its birth, is still fetching.
let pointAtChildFirst = async (~indexer: IndexerRunner.t, ~source: MockSource.t, ~items=[]) => {
  await source.expectItemsQueries([
    {
      where: isFetchingFor(factory, ...),
      reply: Respond({
        items: items->Array.concat([pointed(~blockNumber=50, child)]),
        latestFetchedBlockNumber: 100,
      }),
    },
    {reply: LeavePending},
  ])
  await indexer.waitUntilIdle()
}

let warnings = (indexer: IndexerRunner.t) =>
  indexer.infoAndAboveLogs()->Array.filter(({msg}) => msg->String.startsWith("Skipping"))

// https://github.com/enviodev/hyperindex/issues/1810
describe("An address registered for one contract from two blocks", () => {
  scenario->Scenario.it(
    "is indexed from the earlier block when the later registration arrives first",
    ~sources,
    async (~t, ~indexer, ~source) => {
      let source = source(1337)
      await pointAtChildFirst(~indexer, ~source)
      await source.respondUpTo(
        300,
        ~items=[
          ping(~blockNumber=5, child),
          born(~blockNumber=10, child),
          ping(~blockNumber=10, child),
          ping(~blockNumber=20, child),
          ping(~blockNumber=60, child),
          ping(~blockNumber=200, child),
        ],
      )

      t.expect((
        await pingedBlocks(indexer),
        await registeredChildren(indexer),
        warnings(indexer),
      )).toEqual(([10, 20, 60, 200], [(child, 10)], []))
    },
  )

  scenario->Scenario.it(
    "is indexed from block 0 when the earlier registration is at block 0",
    ~sources,
    async (~t, ~indexer, ~source) => {
      let source = source(1337)
      await pointAtChildFirst(~indexer, ~source)
      await source.respondUpTo(
        300,
        ~items=[
          born(~blockNumber=0, child),
          ping(~blockNumber=0, child),
          ping(~blockNumber=20, child),
        ],
      )

      t.expect((await pingedBlocks(indexer), await registeredChildren(indexer))).toEqual((
        [0, 20],
        [(child, 0)],
      ))
    },
  )

  scenario->Scenario.it(
    "is indexed from the earlier block when one run collects the later registration first",
    ~sources,
    async (~t, ~indexer, ~source) => {
      let source = source(1337)
      await source.respondUpTo(
        300,
        ~items=[
          ping(~blockNumber=5, child),
          spawned(~blockNumber=10, child),
          ping(~blockNumber=20, child),
          pointed(~blockNumber=50, child),
          ping(~blockNumber=60, child),
        ],
      )

      t.expect((
        await pingedBlocks(indexer),
        await registeredChildren(indexer),
        warnings(indexer),
      )).toEqual(([20, 60], [(child, 10)], []))
    },
  )

  scenario->Scenario.it(
    "is indexed from the earlier block when a nested factory registers it",
    ~sources,
    async (~t, ~indexer, ~source) => {
      let source = source(1337)
      await source.expectItemsQueries([
        {
          where: isFetchingFor(factory, ...),
          reply: Respond({items: [opened(~blockNumber=10, hub)], latestFetchedBlockNumber: 100}),
        },
        {reply: LeavePending},
      ])
      await indexer.waitUntilIdle()
      // The hub's partition hasn't answered yet when the wildcard one registers
      // the grandchild from a later block.
      await source.expectItemsQueries([
        {
          where: isAddressFree,
          reply: Respond({items: [born(~blockNumber=80, child)], latestFetchedBlockNumber: 100}),
        },
        {where: isFetchingFor(hub, ...), reply: LeavePending},
        {reply: LeavePending},
      ])
      await indexer.waitUntilIdle()
      await source.respondUpTo(
        300,
        ~items=[
          ping(~blockNumber=20, child),
          made(~blockNumber=30, child),
          ping(~blockNumber=30, child),
          ping(~blockNumber=40, child),
          ping(~blockNumber=90, child),
        ],
      )

      t.expect((
        await pingedBlocks(indexer),
        await registeredChildren(indexer),
        warnings(indexer),
      )).toEqual(([30, 40, 90], [(child, 30)], []))
    },
  )

  scenario->Scenario.it(
    "is indexed from the earlier block when its contract is filtered client-side",
    ~sources,
    ~clientFilterAddressThreshold=1,
    async (~t, ~indexer, ~source) => {
      let source = source(1337)
      await pointAtChildFirst(~indexer, ~source, ~items=[pointed(~blockNumber=40, other)])
      await source.respondUpTo(
        300,
        ~items=[
          ping(~blockNumber=5, child),
          born(~blockNumber=10, child),
          ping(~blockNumber=20, child),
          ping(~blockNumber=60, child),
        ],
      )

      t.expect((
        await pingedBlocks(indexer),
        await registeredChildren(indexer),
        indexer.allLogsAsJson()->Array.some(
          log =>
            log->Dict.get("msg") ===
              Some(
                JSON.String(
                  "Switching contract to client-side address filtering: registered address count crossed the server-side threshold.",
                ),
              ),
        ),
      )).toEqual(([20, 60], [(child, 10), (other, 40)], true))
    },
  )

  scenario->Scenario.it("is restored from the earlier block on restart", ~sources, async (
    ~t,
    ~indexer,
    ~source,
  ) => {
    let source = source(1337)
    await pointAtChildFirst(~indexer, ~source)
    await source.respondUpTo(
      30,
      ~items=[born(~blockNumber=10, child), ping(~blockNumber=20, child)],
    )
    // Lets the throttled write of the batch covering block 30 land.
    await indexer.advanceTime(500)
    let beforeRestart = await registeredChildren(indexer)

    // The resumed run fetches from block 31 again, the factory's pointer included.
    let resumed = await indexer.restart()
    await source.respondUpTo(
      300,
      ~items=[
        ping(~blockNumber=40, child),
        pointed(~blockNumber=50, child),
        ping(~blockNumber=60, child),
      ],
    )
    await resumed.advanceTime(500)

    t.expect((
      beforeRestart,
      await pingedBlocks(resumed),
      await registeredChildren(resumed),
    )).toEqual(([(child, 10)], [20, 40, 60], [(child, 10)]))
  })

  // The registration that moves the address earlier leaves the entry it
  // replaces in the partition that already held it, so until the two
  // partitions merge, both ask the source for the address and its events come
  // back twice. This double fetch is a decision, not an oversight: removing the
  // replaced entry from existing partitions was left out to keep the fix inside
  // the address store, and near the head the address is in no partition's
  // list. Whoever changes this changes the test on purpose.
  scenario->Scenario.it(
    "is fetched by both the partition that held it and the new one, and handled once",
    ~sources,
    async (~t, ~indexer, ~source) => {
      let source = source(1337)
      await pointAtChildFirst(~indexer, ~source)
      await source.expectItemsQueries([
        {
          where: isAddressFree,
          reply: Respond({items: [born(~blockNumber=10, child)], latestFetchedBlockNumber: 100}),
        },
        {where: isFetchingFor(child, ...), reply: LeavePending},
        {reply: LeavePending},
      ])
      await indexer.waitUntilIdle()
      let fetchingChild =
        source.pendingItemsQueries
        ->Array.filter(isFetchingFor(child, ...))
        ->Array.map(query => (query.partitionId, query.fromBlock))
      await source.respondUpTo(
        300,
        ~items=[
          ping(~blockNumber=20, child),
          ping(~blockNumber=60, child),
          ping(~blockNumber=200, child),
        ],
      )

      t.expect((fetchingChild, await pingedBlocks(indexer))).toEqual((
        [("2", 50), ("3", 10)],
        [20, 60, 200],
      ))
    },
  )
})

// https://github.com/enviodev/hyperindex/issues/1810
describe("A rollback after an address moved to an earlier registration", () => {
  // Inside the reorg threshold: registered at 110 after a registration at 150.
  let replaceThenReorg = async (~indexer: IndexerRunner.t, ~source: MockSource.t, ~validUpTo) => {
    source.resolveGetHeightOrThrow(300)
    await source.respondUpTo(99)
    await source.expectItemsQueries([
      {
        where: isFetchingFor(factory, ...),
        reply: Respond({items: [pointed(~blockNumber=150, child)], latestFetchedBlockNumber: 200}),
      },
      {reply: LeavePending},
    ])
    await indexer.waitUntilIdle()
    await source.respondUpTo(
      250,
      ~items=[
        ping(~blockNumber=105, child),
        born(~blockNumber=110, child),
        ping(~blockNumber=110, child),
        ping(~blockNumber=120, child),
        ping(~blockNumber=160, child),
        ping(~blockNumber=240, child),
      ],
    )
    let beforeReorg = (await pingedBlocks(indexer), await registeredChildren(indexer))
    await source.expectItemsQueries([
      {
        where: isAddressFree,
        reply: Respond({
          items: [],
          latestFetchedBlockNumber: 251,
          prevRangeLastBlock: {blockNumber: 250, blockHash: "0x250a"},
        }),
      },
      {reply: LeavePending},
    ])
    await Scenario.driveRollback(~source, ~validUpTo, ~head=251)
    await indexer.waitUntilIdle()
    await indexer.advanceTime(500)
    (beforeReorg, (await pingedBlocks(indexer), await registeredChildren(indexer)))
  }

  let sources: array<Scenario.sourceMock> = [
    {chain: 1337, methods: [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes]},
  ]
  let beforeReorg = ([110, 120, 160, 240], [(child, 110)])

  scenario->Scenario.it("to before both registrations drops the address", ~sources, async (
    ~t,
    ~indexer,
    ~source,
  ) => {
    t.expect(await replaceThenReorg(~indexer, ~source=source(1337), ~validUpTo=100)).toEqual((
      beforeReorg,
      ([], []),
    ))
  })

  scenario->Scenario.it(
    "to between the registrations keeps it from the earlier one",
    ~sources,
    async (~t, ~indexer, ~source) => {
      t.expect(await replaceThenReorg(~indexer, ~source=source(1337), ~validUpTo=130)).toEqual((
        beforeReorg,
        ([110, 120], [(child, 110)]),
      ))
    },
  )

  scenario->Scenario.it(
    "to after both registrations keeps it from the earlier one",
    ~sources,
    async (~t, ~indexer, ~source) => {
      t.expect(await replaceThenReorg(~indexer, ~source=source(1337), ~validUpTo=200)).toEqual((
        beforeReorg,
        ([110, 120, 160], [(child, 110)]),
      ))
    },
  )
})

// https://github.com/enviodev/hyperindex/issues/1810
describe("An address registered twice below its contract's start block", () => {
  // Both registrations are effective from block 200, the contract's start, so
  // only their blocks tell them apart. The reorg takes the later one away.
  lateStartScenario->Scenario.it(
    "survives a rollback that removes the later registration",
    ~sources=[
      {
        chain: 1337,
        methods: [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes],
        // Off `Child`, the config's first contract, or the mock's own
        // registration would lift Child's start block.
        mockEventContract: "Factory",
      },
    ],
    async (~t, ~indexer, ~source) => {
      let source = source(1337)
      source.resolveGetHeightOrThrow(300)
      await source.respondUpTo(99)
      await source.expectItemsQueries([
        {
          where: isFetchingFor(factory, ...),
          reply: Respond({
            items: [pointed(~blockNumber=150, child)],
            latestFetchedBlockNumber: 200,
          }),
        },
        {reply: LeavePending},
      ])
      await indexer.waitUntilIdle()
      await source.respondUpTo(
        250,
        ~items=[born(~blockNumber=110, child), ping(~blockNumber=210, child)],
      )
      await source.expectItemsQueries([
        {
          where: isAddressFree,
          reply: Respond({
            items: [],
            latestFetchedBlockNumber: 251,
            prevRangeLastBlock: {blockNumber: 250, blockHash: "0x250a"},
          }),
        },
        {reply: LeavePending},
      ])
      // The new chain keeps the birth at 110 but not the pointer at 150, and
      // its ping at 210 sits at another log index than the orphaned one.
      await Scenario.driveRollback(
        ~source,
        ~validUpTo=130,
        ~head=251,
        ~refetched=[ping(~blockNumber=210, ~logIndex=2, child)],
      )
      await indexer.waitUntilIdle()
      await source.respondUpTo(300, ~items=[ping(~blockNumber=280, child)])
      await indexer.advanceTime(500)

      t.expect((await handledPingIds(indexer), await registeredChildren(indexer))).toEqual((
        ["210-2", "280-1"],
        [(child, 110)],
      ))
    },
  )
})
