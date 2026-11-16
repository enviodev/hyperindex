open Vitest

// A batch the server refuses part of. Every write in it shares one
// transaction, so the entity it could store, the history row, the checkpoint
// and the chain's progress must all be missing afterwards, and a restarted
// indexer has to pick up from the last batch that did commit.

let scenario = Scenario.make(
  ~configYaml=`
name: storage-write-refusal
save_full_history: true
chains:
  - id: 1337
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 1
    contracts:
      - name: Gravatar
        address: "0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3"
        events:
          - event: "TestEvent(string id, uint256 count)"
`,
  ~schema=`
type Tally {
  id: ID!
  count: Int!
}
`,
  ~handlers=`
import { indexer } from "envio";

indexer.onEvent({ contract: "Gravatar", event: "TestEvent" }, async ({ event, context }) => {
  context.Tally.set({ id: event.params.id, count: Number(event.params.count) });
});
`,
)

type tally = {id: string, count: int}

let setTally = (~block, ~logIndex=0, ~id: string, ~count: bigint): MockSource.itemMock => {
  event: "Gravatar.TestEvent",
  blockNumber: block,
  logIndex,
  params: dict{
    "id": id->(Utils.magic: string => unknown),
    "count": count->(Utils.magic: bigint => unknown),
  },
}

// Past what an `integer` column holds. JavaScript has no trouble with it, so
// the refusal comes from the server.
let tooLarge = 2147483648n
let tooSmall = -2147483649n

type stored = {tallies: array<tally>, history: int, checkpoints: int, progress: array<int>}

let read = async (indexer: IndexerRunner.t) => {
  let tallies: array<tally> = await indexer.query("Tally")
  let history: array<Change.t<tally>> = await indexer.queryHistory("Tally")
  {
    tallies: tallies->Array.toSorted((a, b) => String.compare(a.id, b.id)),
    history: history->Array.length,
    checkpoints: (await indexer.queryCheckpoints())->Array.length,
    progress: (await indexer.queryChains())->Array.map(chain => chain.progressBlock),
  }
}

describe("A batch the server refuses", () => {
  let refusal = Scenario.captureRefusal()

  scenario->Scenario.it(
    "commits nothing from it, and a restart resumes after the last good batch",
    ~sources=[{chain: 1337, methods: [#getHeightOrThrow, #getItemsOrThrow]}],
    ~onError=refusal.onError,
    async (~t, ~indexer, ~source) => {
      let sourceMock = source(1337)
      await Scenario.resolveInitialHeight(~source=sourceMock, ~head=100)

      await sourceMock.expectItemsQueries([
        {
          fromBlock: 1,
          reply: Respond({
            items: [setTally(~block=1, ~id="kept", ~count=1n)],
            latestFetchedBlockNumber: 1,
          }),
        },
      ])
      await indexer.getBatchWritePromise()
      let committed = await read(indexer)

      await sourceMock.expectItemsQueries([
        {
          coversBlock: 2,
          reply: Respond({
            items: [
              setTally(~block=2, ~id="kept", ~count=2n),
              setTally(~block=2, ~logIndex=1, ~id="refused", ~count=tooLarge),
            ],
            latestFetchedBlockNumber: 2,
          }),
        },
      ])
      let reason = await refusal.awaitRefusalReason()
      let afterRefusal = await read(indexer)

      sourceMock.setAutoHeight(100)
      let restarted = await indexer.restart()
      await sourceMock.expectItemsQueries([
        {
          coversBlock: 2,
          reply: Respond({
            items: [setTally(~block=2, ~id="kept", ~count=2n)],
            latestFetchedBlockNumber: 2,
          }),
        },
      ])
      await restarted.getBatchWritePromise()
      let resumed = await read(restarted)

      t.expect((
        reason->Option.map(reason => reason->String.includes("out of range")),
        afterRefusal,
        resumed,
      )).toEqual((
        Some(true),
        committed,
        {tallies: [{id: "kept", count: 2}], history: 2, checkpoints: 2, progress: [2]},
      ))
    },
  )
})

describe("A value below what an integer column holds", () => {
  let refusal = Scenario.captureRefusal()

  scenario->Scenario.it(
    "is refused like one above it",
    ~sources=[{chain: 1337, methods: [#getHeightOrThrow, #getItemsOrThrow]}],
    ~onError=refusal.onError,
    async (~t, ~indexer as _, ~source) => {
      let sourceMock = source(1337)
      await Scenario.resolveInitialHeight(~source=sourceMock, ~head=100)
      await sourceMock.expectItemsQueries([
        {
          fromBlock: 1,
          reply: Respond({
            items: [setTally(~block=1, ~id="refused", ~count=tooSmall)],
            latestFetchedBlockNumber: 1,
          }),
        },
      ])
      let reason = await refusal.awaitRefusalReason()

      t.expect(reason->Option.map(reason => reason->String.includes("out of range"))).toEqual(
        Some(true),
      )
    },
  )
})
