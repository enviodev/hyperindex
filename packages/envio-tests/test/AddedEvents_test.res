open Vitest

// What `envio start --backfill-added-events` does with events config.yaml
// gained on a contract the database already indexes: the chain carries on at
// the head with every event while a catch-up indexes the added ones' history.

let token = "0x00000000000000000000000000000000000000a1"

let configYaml = (~events) =>
  `
name: added-events
rollback_on_reorg: true
chains:
  - id: 1337
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 0
    max_reorg_depth: 10
    contracts:
      - name: Token
        address: "${token}"
        events:${events
    ->Array.map(event =>
      `
          - event: "${event}"`
    )
    ->Array.join("")}
`

let schema = `
type Seen {
  id: ID!
  handled: Int!
}
`

// Each handler writes a row of its own event and counts how often it ran, so
// an event indexed twice shows.
let handler = (~event, ~prefix) =>
  `
indexer.onEvent({ contract: "Token", event: "${event}" }, async ({ event, context }) => {
  const id = \`${prefix}-\${event.block.number}\`;
  const seen = await context.Seen.get(id);
  context.Seen.set({ id, handled: (seen?.handled ?? 0) + 1 });
});
`
let transferHandler = handler(~event="Transfer", ~prefix="transfer")
let approvalHandler = handler(~event="Approval", ~prefix="approval")
let importIndexer = `import { indexer } from "envio";`

let deployed = Scenario.make(
  ~configYaml=configYaml(~events=["Transfer()"]),
  ~schema,
  ~handlers=importIndexer ++ transferHandler,
)

let withApproval = Scenario.make(
  ~configYaml=configYaml(~events=["Transfer()", "Approval()"]),
  ~schema,
  ~handlers=importIndexer ++ transferHandler ++ approvalHandler,
)

// The same edit with a handler that fails the first time it meets block 60,
// which is what stops the catch-up part way.
let withFailingApproval = Scenario.make(
  ~configYaml=configYaml(~events=["Transfer()", "Approval()"]),
  ~schema,
  ~handlers=importIndexer ++
  transferHandler ++ `
let hasFailed = false;
indexer.onEvent({ contract: "Token", event: "Approval" }, async ({ event, context }) => {
  if (event.block.number === 60 && !hasFailed && !context.isPreload) {
    hasFailed = true;
    throw new Error("Stopped part way");
  }
  const id = \`approval-\${event.block.number}\`;
  const seen = await context.Seen.get(id);
  context.Seen.set({ id, handled: (seen?.handled ?? 0) + 1 });
});
`,
)

let withMint = Scenario.make(
  ~configYaml=configYaml(~events=["Transfer()", "Approval()", "Mint()"]),
  ~schema,
  ~handlers=importIndexer ++
  transferHandler ++
  approvalHandler ++
  handler(~event="Mint", ~prefix="mint"),
)

let sources: array<Scenario.sourceMock> = [{chain: 1337, autoHeight: 1000}]

let item = (event, ~blockNumber): MockSource.itemMock => {
  event: `Token.${event}`,
  blockNumber,
  logIndex: 0,
  srcAddress: token,
  params: dict{},
}

let handledIds = async (indexer: IndexerRunner.t) =>
  (await indexer.query("Seen"))
  ->Array.flatMap((seen: {"id": string, "handled": int}) =>
    Array.make(~length=seen["handled"], seen["id"])
  )
  ->Array.toSorted(String.compare)

let progressBlocks = async (indexer: IndexerRunner.t) =>
  (await indexer.queryChains())->Array.map(row => row.progressBlock)

let edited = (source, ~backfillAddedEvents, ~scenario=withApproval) => {
  ...scenario.config->Scenario.withMockSources(~sources=[(1337, source)]),
  backfillAddedEvents,
}

let indexTransfers = async (~indexer: IndexerRunner.t, ~source: MockSource.t) => {
  await source.respondUpTo(
    100,
    ~items=[item("Transfer", ~blockNumber=10), item("Transfer", ~blockNumber=50)],
  )
  // Lets the throttled write of the batch covering block 100 land.
  await indexer.advanceTime(500)
}

// What the database holds of each chain's catch-up: where it ends and how far
// it has got. Empty once the added events are in.
let catchUps = async (indexer: IndexerRunner.t) => {
  let rows = ref([])
  await indexer.usePostgresSql(async sql => {
    let found: array<{
      "untilBlock": Null.t<int>,
      "progressBlock": Null.t<int>,
    }> = await sql->Sql.queryForTests(
      `SELECT "until_block" AS "untilBlock", "progress_block" AS "progressBlock" FROM "${indexer.pgSchema}"."envio_added_events" ORDER BY "chain_id";`,
    )
    rows :=
      found->Array.map(row => (
        row["untilBlock"]->Null.toOption,
        row["progressBlock"]->Null.toOption,
      ))
  })
  rows.contents
}

let isCatchUp = (query: MockSource.pendingItemsQuery) => query.fromBlock <= 100
let isAtHead = (query: MockSource.pendingItemsQuery) => query.fromBlock > 100

// https://github.com/enviodev/hyperindex/issues/1878
describe("Events added to a contract the database already indexes", () => {
  deployed->Scenario.it(
    "are indexed up to where the chain stood while the chain carries on at the head",
    ~sources,
    ~edited=[withApproval],
    async (~t, ~indexer, ~source) => {
      let source = source(1337)
      await indexTransfers(~indexer, ~source)

      let resumed = await indexer.restart(~config=edited(source, ~backfillAddedEvents=true), ())
      await source.expectItemsQueries([
        {
          where: isAtHead,
          reply: Respond({
            items: [item("Transfer", ~blockNumber=150), item("Approval", ~blockNumber=160)],
            latestFetchedBlockNumber: 200,
          }),
        },
        {reply: LeavePending},
      ])
      await resumed.advanceTime(500)
      let atHeadMeanwhile = (
        await handledIds(resumed),
        await progressBlocks(resumed),
        await catchUps(resumed),
      )

      await source.expectItemsQueries([
        {
          where: isCatchUp,
          reply: Respond({
            items: [item("Approval", ~blockNumber=20), item("Approval", ~blockNumber=60)],
          }),
        },
        {reply: LeavePending},
      ])
      let caughtUp =
        source.repliedItemsQueries->Array.map(query => (query.fromBlock, query.toBlock))
      await resumed.addedEventsFinished()

      t.expect((
        atHeadMeanwhile,
        caughtUp,
        await handledIds(resumed),
        await progressBlocks(resumed),
        await catchUps(resumed),
      )).toEqual((
        (
          ["approval-160", "transfer-10", "transfer-150", "transfer-50"],
          [200],
          [(Some(100), None)],
        ),
        [(0, MockSource.Bounded(100))],
        [
          "approval-160",
          "approval-20",
          "approval-60",
          "transfer-10",
          "transfer-150",
          "transfer-50",
        ],
        [200],
        [],
      ))
    },
  )

  deployed->Scenario.it(
    "are picked up where an interrupted run left them, without the flag",
    ~sources,
    ~edited=[withFailingApproval],
    ~onError=_ => (),
    async (~t, ~indexer, ~source) => {
      let source = source(1337)
      await indexTransfers(~indexer, ~source)

      let interrupted = await indexer.restart(
        ~config=edited(source, ~backfillAddedEvents=true, ~scenario=withFailingApproval),
        (),
      )
      await source.expectItemsQueries([
        {
          where: isCatchUp,
          reply: Respond({
            items: [item("Approval", ~blockNumber=20)],
            latestFetchedBlockNumber: 40,
          }),
        },
        {reply: LeavePending},
      ])
      // Lets the throttled write of the catch-up's batch covering block 40 land.
      await interrupted.advanceTime(500)
      await source.expectItemsQueries([
        {where: isCatchUp, reply: Respond({items: [item("Approval", ~blockNumber=60)]})},
        {reply: LeavePending},
      ])
      await interrupted.addedEventsFinished()
      let whenInterrupted = (await catchUps(interrupted), await progressBlocks(interrupted))

      let resumed = await interrupted.restart(
        ~config=edited(source, ~backfillAddedEvents=false, ~scenario=withFailingApproval),
        (),
      )
      await source.expectItemsQueries([
        {where: isCatchUp, reply: Respond({items: [item("Approval", ~blockNumber=60)]})},
        {reply: LeavePending},
      ])
      let continuedFrom = source.repliedItemsQueries->Array.map(query => query.fromBlock)
      await resumed.addedEventsFinished()

      t.expect((
        whenInterrupted,
        continuedFrom,
        await handledIds(resumed),
        await catchUps(resumed),
      )).toEqual((
        ([(Some(100), Some(40))], [100]),
        [41],
        ["approval-20", "approval-60", "transfer-10", "transfer-50"],
        [],
      ))
    },
  )

  deployed->Scenario.it(
    "are refused while an earlier addition is still being indexed",
    ~sources,
    ~edited=[withApproval, withMint],
    async (~t, ~indexer, ~source) => {
      let source = source(1337)
      await indexTransfers(~indexer, ~source)

      let catchingUp = await indexer.restart(~config=edited(source, ~backfillAddedEvents=true), ())
      let refusal = switch await catchingUp.restart(
        ~config=edited(source, ~backfillAddedEvents=true, ~scenario=withMint),
        (),
      ) {
      | _ => None
      | exception JsExn(e) => e->JsExn.message->Option.map(IndexerRunner.stripLogsLink)
      }

      t.expect(refusal).toEqual(
        Some(
          "An earlier `--backfill-added-events` run hasn't finished on chain 1337. Start the indexer with the config that run used and let it finish before adding more events.",
        ),
      )
    },
  )

  // What the catch-up writes keeps no history, so it stays where no reorg can
  // reach: a reorg depth behind the head, like any chain before it starts
  // keeping one.
  deployed->Scenario.it(
    "wait for the blocks a reorg can still reach to pass out of its reach",
    ~sources=[{chain: 1337, autoHeight: 105}],
    ~edited=[withApproval],
    async (~t, ~indexer, ~source) => {
      let source = source(1337)
      await indexTransfers(~indexer, ~source)

      let resumed = await indexer.restart(~config=edited(source, ~backfillAddedEvents=true), ())
      await source.expectItemsQueries([
        {where: isCatchUp, reply: Respond({items: [item("Approval", ~blockNumber=20)]})},
        {reply: LeavePending},
      ])
      let firstRange =
        source.repliedItemsQueries->Array.map(query => (query.fromBlock, query.toBlock))

      source.setAutoHeight(120)
      await resumed.advanceTime(60_000)
      await source.expectItemsQueries([
        {where: isCatchUp, reply: Respond({items: [item("Approval", ~blockNumber=97)]})},
        {reply: LeavePending},
      ])
      let secondRange =
        source.repliedItemsQueries->Array.map(query => (query.fromBlock, query.toBlock))
      await resumed.addedEventsFinished()

      t.expect((firstRange, secondRange, await handledIds(resumed))).toEqual((
        [(0, MockSource.Bounded(94))],
        [(95, MockSource.Bounded(100))],
        ["approval-20", "approval-97", "transfer-10", "transfer-50"],
      ))
    },
  )
})

let factory = "0x00000000000000000000000000000000000000f1"
let child = "0x00000000000000000000000000000000000000c1"

// `Factory` registers a `Child` at block 30. `Idle` has no address on the
// chain, so an event it gains has no history to index.
let factoryConfigYaml = (~childEvents=["Ping()"], ~idleEvents=["Noop()"], ~factoryEvents=[]) => {
  let events = events =>
    events
    ->Array.map(event =>
      `
          - event: "${event}"`
    )
    ->Array.join("")
  `
name: added-events-factory
rollback_on_reorg: true
chains:
  - id: 1337
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 0
    max_reorg_depth: 10
    contracts:
      - name: Factory
        address: "${factory}"
        events:${events(["Created(address child)"]->Array.concat(factoryEvents))}
      - name: Child
        events:${events(childEvents)}
      - name: Idle
        events:${events(idleEvents)}
`
}

let countHandler = (~contract, ~event) =>
  `
indexer.onEvent({ contract: "${contract}", event: "${event}" }, async ({ event, context }) => {
  const id = \`${event->String.toLowerCase}-\${event.block.number}\`;
  const seen = await context.Seen.get(id);
  context.Seen.set({ id, handled: (seen?.handled ?? 0) + 1 });
});
`

let factoryHandlers =
  importIndexer ++
  `
indexer.contractRegister({ contract: "Factory", event: "Created" }, async ({ event, context }) => {
  context.chain.Child.add(event.params.child);
});
` ++
  countHandler(~contract="Child", ~event="Ping") ++
  countHandler(~contract="Idle", ~event="Noop")

let factoryDeployed = Scenario.make(
  ~configYaml=factoryConfigYaml(),
  ~schema,
  ~handlers=factoryHandlers,
)

let withPong = Scenario.make(
  ~configYaml=factoryConfigYaml(~childEvents=["Ping()", "Pong()"]),
  ~schema,
  ~handlers=factoryHandlers ++ countHandler(~contract="Child", ~event="Pong"),
)

let withIdleExtra = Scenario.make(
  ~configYaml=factoryConfigYaml(~idleEvents=["Noop()", "Extra()"]),
  ~schema,
  ~handlers=factoryHandlers ++ countHandler(~contract="Idle", ~event="Extra"),
)

let withRegisteringEvent = Scenario.make(
  ~configYaml=factoryConfigYaml(~factoryEvents=["Spawned(address child)"]),
  ~schema,
  ~handlers=factoryHandlers ++ `
indexer.contractRegister({ contract: "Factory", event: "Spawned" }, async ({ event, context }) => {
  context.chain.Child.add(event.params.child);
});
`,
)

let created = (~blockNumber): MockSource.itemMock => {
  event: "Factory.Created",
  blockNumber,
  logIndex: 0,
  srcAddress: factory,
  params: dict{"child": child->(Utils.magic: string => unknown)},
}

let childItem = (event, ~blockNumber): MockSource.itemMock => {
  event: `Child.${event}`,
  blockNumber,
  logIndex: 1,
  srcAddress: child,
  params: dict{},
}

let indexChild = async (~indexer: IndexerRunner.t, ~source: MockSource.t) => {
  await source.respondUpTo(
    100,
    ~items=[created(~blockNumber=30), childItem("Ping", ~blockNumber=40)],
  )
  // Lets the throttled write of the batch covering block 100 land.
  await indexer.advanceTime(500)
}

let editedAs = (scenario: Scenario.t, source) => {
  ...scenario.config->Scenario.withMockSources(~sources=[(1337, source)]),
  backfillAddedEvents: true,
}

// https://github.com/enviodev/hyperindex/issues/1878
describe("Events added beside dynamically registered contracts", () => {
  factoryDeployed->Scenario.it(
    "are fetched for the addresses the database holds, from the block each was registered at",
    ~sources,
    ~edited=[withPong],
    async (~t, ~indexer, ~source) => {
      let source = source(1337)
      await indexChild(~indexer, ~source)

      let resumed = await indexer.restart(~config=withPong->editedAs(source), ())
      await source.expectItemsQueries([
        {where: isCatchUp, reply: Respond({items: [childItem("Pong", ~blockNumber=35)]})},
        {reply: LeavePending},
      ])
      let fetched =
        source.repliedItemsQueries->Array.map(
          query => (
            query.fromBlock,
            query.toBlock,
            query->MockSource.addresses->Array.map(Address.toString),
            (query->MockSource.selection).onEventRegistrations->Array.map(
              registration => registration.eventConfig.name,
            ),
          ),
        )
      await resumed.addedEventsFinished()

      t.expect((fetched, await handledIds(resumed), await progressBlocks(resumed))).toEqual((
        [(30, MockSource.Bounded(100), [child], ["Pong"])],
        ["ping-40", "pong-35"],
        [100],
      ))
    },
  )

  factoryDeployed->Scenario.it(
    "have nothing to index on a chain with no address for them",
    ~sources,
    ~edited=[withIdleExtra],
    async (~t, ~indexer, ~source) => {
      let source = source(1337)
      await indexChild(~indexer, ~source)

      let resumed = await indexer.restart(~config=withIdleExtra->editedAs(source), ())
      await resumed.addedEventsFinished()

      t.expect((
        await catchUps(resumed),
        resumed.infoAndAboveLogs()
        ->Array.map(({msg}) => msg)
        ->Array.filter(
          msg =>
            msg->String.includes("added events") || msg->String.startsWith("Indexing the events"),
        ),
      )).toEqual(([], ["The added events are in."]))
    },
  )

  // The addresses it registers would have events the indexer already went
  // past, which only a resync indexes.
  factoryDeployed->Scenario.it(
    "are refused when one of them registers contracts",
    ~sources,
    ~edited=[withRegisteringEvent],
    async (~t, ~indexer, ~source) => {
      let source = source(1337)
      await indexChild(~indexer, ~source)

      let refusal = switch await indexer.restart(
        ~config=withRegisteringEvent->editedAs(source),
        (),
      ) {
      | _ => None
      | exception JsExn(e) => e->JsExn.message->Option.map(IndexerRunner.stripLogsLink)
      }

      t.expect((refusal, await catchUps(indexer))).toEqual((
        Some(
          "`--backfill-added-events` can't take Factory.Spawned on chain 1337: it has a contractRegister, and the addresses it registers would have events the indexer already went past. Remove the contractRegister and start again, or reset the indexer.",
        ),
        [(None, None)],
      ))
    },
  )
})

let twoChainsConfigYaml = (~events) => {
  let chain = id =>
    `
  - id: ${id->Int.toString}
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 0
    max_reorg_depth: 10
    contracts:
      - name: Token
        address: "${token}"`
  `
name: added-events-two-chains
rollback_on_reorg: true
contracts:
  - name: Token
    events:${events
    ->Array.map(event =>
      `
      - event: "${event}"`
    )
    ->Array.join("")}
chains:${chain(1337)}${chain(1338)}
`
}

let twoChainsDeployed = Scenario.make(
  ~configYaml=twoChainsConfigYaml(~events=["Transfer()"]),
  ~schema,
  ~handlers=importIndexer ++ transferHandler,
)

let twoChainsWithApproval = Scenario.make(
  ~configYaml=twoChainsConfigYaml(~events=["Transfer()", "Approval()"]),
  ~schema,
  ~handlers=importIndexer ++ transferHandler ++ approvalHandler,
)

// https://github.com/enviodev/hyperindex/issues/1878
describe("Events added to a contract two chains index", () => {
  twoChainsDeployed->Scenario.it(
    "are indexed on each chain up to where that chain stood",
    ~sources=[{chain: 1337, autoHeight: 1000}, {chain: 1338, autoHeight: 1000}],
    ~edited=[twoChainsWithApproval],
    async (~t, ~indexer, ~source) => {
      let (first, second) = (source(1337), source(1338))
      await first.respondUpTo(100, ~items=[item("Transfer", ~blockNumber=10)])
      await second.respondUpTo(80, ~items=[item("Transfer", ~blockNumber=12)])
      // Lets the throttled write of the batches covering those blocks land.
      await indexer.advanceTime(500)

      let resumed = await indexer.restart(
        ~config={
          ...twoChainsWithApproval.config->Scenario.withMockSources(
            ~sources=[(1337, first), (1338, second)],
          ),
          backfillAddedEvents: true,
        },
        (),
      )
      await first.expectItemsQueries([
        {
          where: query => query.fromBlock === 0,
          reply: Respond({items: [item("Approval", ~blockNumber=20)]}),
        },
        {reply: LeavePending},
      ])
      await second.expectItemsQueries([
        {
          where: query => query.fromBlock === 0,
          reply: Respond({items: [item("Approval", ~blockNumber=22)]}),
        },
        {reply: LeavePending},
      ])
      let fetched =
        [first, second]->Array.flatMap(
          source =>
            source.repliedItemsQueries->Array.map(query => (query.fromBlock, query.toBlock)),
        )
      await resumed.addedEventsFinished()

      t.expect((fetched, await handledIds(resumed), await progressBlocks(resumed))).toEqual((
        [(0, MockSource.Bounded(100)), (0, MockSource.Bounded(80))],
        ["approval-20", "approval-22", "transfer-10", "transfer-12"],
        [100, 80],
      ))
    },
  )
})
