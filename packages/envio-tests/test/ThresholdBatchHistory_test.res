open Vitest

// Whether a batch's rows get history is decided when the batch is created, from
// the chain states it was created against, and is carried on the batch — the
// checkpoints it writes follow it. Re-deriving the same decision at write time
// reads a threshold flag that may have flipped since, so a batch created below
// the reorg threshold and flushed after the indexer entered it writes entity
// history rows anchored on checkpoints its own decision keeps out of the
// database.

let scenario = Scenario.make(
  ~configYaml=`
name: threshold-batch-history
rollback_on_reorg: true
chains:
  - id: 1337
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 1
    max_reorg_depth: 200
    contracts:
      - name: Gravatar
        address: "0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3"
        events:
          - event: "TestEvent()"
`,
  ~schema=`
type SimpleEntity {
  id: ID!
  value: String!
}
`,
)

type simpleEntity = {id: string, value: string}
type simpleEntityOps = {set: simpleEntity => unit}
type handlerContext = {@as("SimpleEntity") simpleEntity: simpleEntityOps}

let contextOf = (args: Internal.handlerArgs) =>
  args.context->(Utils.magic: Internal.handlerContext => handlerContext)

let setEntity = (~block, ~value, ~onHandled=() => ()): MockSource.itemMock => {
  blockNumber: block,
  logIndex: 0,
  handler: async args => {
    (args->contextOf).simpleEntity.set({id: "1", value})
    onHandled()
  },
}

let showKeep = (keep: HistoryPolicy.keep) =>
  switch keep {
  | Keep => "Keep"
  | Skip => "Skip"
  }

let showPolicy = (policy: HistoryPolicy.t) =>
  switch policy {
  | Shared(keep) => `Shared(${keep->showKeep})`
  | ByChain(_) => "ByChain"
  }

// The stall is driven from the test body but installed by `mapStorage`, which
// is an argument to the test rather than part of its body — so the handles live
// out here, where both can reach them.
let stallWriteBatch: ref<option<promise<unit>>> = ref(None)
let writes: array<string> = []

// The threshold metric is read asynchronously, so it can't be polled through
// `Scenario.waitUntil`, whose predicate is synchronous.
let waitForThreshold = async (indexer: IndexerRunner.t) => {
  let entered = ref(false)
  let attempts = ref(0)
  while !entered.contents && attempts.contents < 1000 {
    attempts := attempts.contents + 1
    entered :=
      (await indexer.metric("envio_reorg_threshold"))->Array.some(metric => metric.value === "1")
    if !entered.contents {
      await Utils.delay(1)
    }
  }
  if !entered.contents {
    JsError.throwWithMessage("Timed out waiting for the indexer to enter the reorg threshold")
  }
}

describe("A batch keeps the history decision it was created with", () => {
  scenario->Scenario.it(
    "Writes a below-threshold batch's entity rows on the batch's own decision, not the live threshold",
    ~sources=[{chain: 1337, methods: [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes]}],
    ~reorgThresholdReadyTolerance=0,
    ~mapStorage=storage => {
      ...storage,
      writeBatch: (
        ~batch,
        ~rollback,
        ~config,
        ~allEntities,
        ~updatedEffectsCache,
        ~updatedEntities,
        ~registeredAddresses,
        ~chainMetaData,
        ~onWrite,
      ) => {
        writes
        ->Array.push(
          `${batch.history->showPolicy}/${updatedEntities
            ->Array.map(updated => updated.history->showKeep)
            ->Array.join(",")}`,
        )
        ->ignore
        let run = async () => {
          switch stallWriteBatch.contents {
          | Some(gate) => await gate
          | None => ()
          }
          await storage.writeBatch(
            ~batch,
            ~rollback,
            ~config,
            ~allEntities,
            ~updatedEffectsCache,
            ~updatedEntities,
            ~registeredAddresses,
            ~chainMetaData,
            ~onWrite,
          )
        }
        run()
      },
    },
    async (~t, ~indexer, ~source) => {
      let sourceMock = source(1337)
      await Utils.delay(0)
      // max_reorg_depth holds the chain 200 blocks below the head of 300, so
      // everything up to block 100 is fetched and processed below the threshold.
      await Scenario.resolveInitialHeight(~t, ~source=sourceMock, ~head=300)

      // Stall the first write so the batches behind it stay queued.
      let resolveStall = ref(() => ())
      stallWriteBatch := Some(Promise.make((resolve, _reject) => resolveStall := (() => resolve())))
      sourceMock.resolveGetItemsOrThrow(
        [setEntity(~block=10, ~value="first")],
        ~latestFetchedBlockNumber=10,
      )
      await Scenario.waitUntil(
        () => writes->Utils.Array.notEmpty,
        ~message="the first batch's write to start",
      )

      // Queued behind the stalled write, and still created below the threshold.
      let queuedProcessed = ref(false)
      sourceMock.resolveGetItemsOrThrow(
        [setEntity(~block=50, ~value="queued", ~onHandled=() => queuedProcessed := true)],
        ~filter=MockSource.coveringBlock(11),
        ~latestFetchedBlockNumber=50,
      )
      await Scenario.waitUntil(
        () => queuedProcessed.contents,
        ~message="the queued batch's handler to run",
      )

      // Reaching the pre-threshold head is what makes the indexer enter the
      // threshold — while the batches below it are still unwritten.
      sourceMock.resolveGetItemsOrThrow(
        [],
        ~filter=MockSource.coveringBlock(51),
        ~latestFetchedBlockNumber=100,
      )
      await waitForThreshold(indexer)

      stallWriteBatch := None
      resolveStall.contents()
      await indexer.getBatchWritePromise()

      t.expect(
        writes->Array.join(" | "),
        ~message="A batch that keeps no checkpoints writes no entity history either, whatever the threshold has since become",
      ).toEqual("Shared(Skip)/Skip | Shared(Skip)/Skip")
    },
  )
})
