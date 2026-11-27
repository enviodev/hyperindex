open Vitest

let scenarioWith = (~handlers, ~endBlock="") =>
  Scenario.make(
    ~configYaml=`
name: fetch-state-start-block-range
rollback_on_reorg: false
contracts:
  - name: Token
    events:
      - event: "Transfer()"
      - event: "Approval()"
chains:
  - id: 1337
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 0
    max_reorg_depth: 0${endBlock}
    contracts:
      - name: Token
`,
    ~schema=`
type Seen {
  id: ID!
}
`,
    ~handlers=`
import { indexer } from "envio";
${handlers}
`,
  )

let wildcard = (~event, ~startBlock=?) =>
  switch startBlock {
  | Some(startBlock) =>
    `indexer.onEvent({ contract: "Token", event: "${event}", wildcard: true, where: { block: { number: { _gte: ${startBlock->Int.toString} } } } }, async () => {});`
  | None =>
    `indexer.onEvent({ contract: "Token", event: "${event}", wildcard: true }, async () => {});`
  }

type queryShape = {
  fromBlock: int,
  toBlock: MockSource.toBlock,
  events: array<string>,
}

let eventNames = ["Transfer", "Approval"]

let pendingShapes = (source: MockSource.t) =>
  source.pendingItemsQueries->Array.map(query => {
    fromBlock: query.fromBlock,
    toBlock: query.toBlock,
    events: (query->MockSource.selection).onEventRegistrationIndexes->Array.map(index =>
      eventNames->Array.getUnsafe(index)
    ),
  })

let firstQueries = async (
  ~indexer: IndexerRunner.t,
  ~source: (int, ~index: int=?) => MockSource.t,
  ~head,
) => {
  let sync = source(1337)
  await sync.expectNewHeightCalls(1)
  sync.resolveGetHeightOrThrow(head)
  await sync.expectItemsQueries([{reply: LeavePending}])
  await indexer.advanceTime(10)
  sync->pendingShapes
}

let restricted = scenarioWith(~handlers=wildcard(~event="Transfer", ~startBlock=500))
let twoRestricted = scenarioWith(
  ~handlers=wildcard(~event="Transfer", ~startBlock=900) ++
  wildcard(~event="Approval", ~startBlock=500),
)
let mixed = scenarioWith(
  ~handlers=wildcard(~event="Transfer", ~startBlock=500) ++ wildcard(~event="Approval"),
)
let restrictedPastEndBlock = scenarioWith(
  ~handlers=wildcard(~event="Transfer", ~startBlock=500),
  ~endBlock="\n    end_block: 200",
)

describe("Indexing plan: start blocks over the indexer loop", () => {
  restricted->Scenario.it(
    "Starts a partition at its registration's start block",
    ~sources=[{chain: 1337}],
    async (~t, ~indexer, ~source) => {
      t.expect(await firstQueries(~indexer, ~source, ~head=1000)).toEqual([
        {fromBlock: 500, toBlock: Unbounded, events: ["Transfer"]},
      ])
    },
  )

  twoRestricted->Scenario.it(
    "Starts a partition at the earliest of its registrations' start blocks",
    ~sources=[{chain: 1337}],
    async (~t, ~indexer, ~source) => {
      t.expect(await firstQueries(~indexer, ~source, ~head=1000)).toEqual([
        {fromBlock: 500, toBlock: Unbounded, events: ["Transfer", "Approval"]},
      ])
    },
  )

  mixed->Scenario.it(
    "Starts a partition at the chain start when a registration has no start block",
    ~sources=[{chain: 1337}],
    async (~t, ~indexer, ~source) => {
      t.expect(await firstQueries(~indexer, ~source, ~head=1000)).toEqual([
        {fromBlock: 0, toBlock: Unbounded, events: ["Transfer", "Approval"]},
      ])
    },
  )

  restricted->Scenario.it(
    "Waits for new blocks while the start block is past the head",
    ~sources=[{chain: 1337}],
    async (~t, ~indexer, ~source) => {
      let sync = source(1337)
      await sync.expectNewHeightCalls(1)
      sync.resolveGetHeightOrThrow(100)
      await indexer.advanceTime(10_000)
      let pastHead = sync->pendingShapes
      sync.setAutoHeight(600)
      await indexer.advanceTime(10_000)
      await sync.expectNewHeightCallsAtLeast(1)
      await sync.expectItemsQueries([{reply: LeavePending}])
      t.expect((pastHead, sync->pendingShapes)).toEqual((
        [],
        [{fromBlock: 500, toBlock: Unbounded, events: ["Transfer"]}],
      ))
    },
  )

  let exited = ref(false)
  restrictedPastEndBlock->Scenario.it(
    "Exits without a query when the start block is past the end block",
    ~sources=[{chain: 1337}],
    ~onExit=() => exited := true,
    async (~t, ~indexer, ~source) => {
      let sync = source(1337)
      sync.resolveGetHeightOrThrow(1000)
      await indexer.advanceTime(10_000)
      t.expect((sync->pendingShapes, exited.contents)).toEqual(([], true))
    },
  )

  let narrowing = endBlock =>
    scenarioWith(
      ~handlers=wildcard(~event="Transfer", ~startBlock=100) ++ wildcard(~event="Approval"),
      ~endBlock=`\n    end_block: ${endBlock->Int.toString}`,
    )

  narrowing(
    99,
  )->Scenario.it(
    "Leaves a registration out of a query whose range ends before its start block",
    ~sources=[{chain: 1337}],
    async (~t, ~indexer, ~source) => {
      t.expect(await firstQueries(~indexer, ~source, ~head=1000)).toEqual([
        {fromBlock: 0, toBlock: Bounded(99), events: ["Approval"]},
      ])
    },
  )

  narrowing(100)->Scenario.it(
    "Keeps a registration in a query whose range reaches its start block",
    ~sources=[{chain: 1337}],
    async (~t, ~indexer, ~source) => {
      t.expect(await firstQueries(~indexer, ~source, ~head=1000)).toEqual([
        {fromBlock: 0, toBlock: Bounded(100), events: ["Transfer", "Approval"]},
      ])
    },
  )
})
