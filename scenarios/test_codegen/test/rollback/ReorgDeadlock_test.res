open Vitest

// Reproduction for the v3.0.0 "reorg -> rollback -> reorg" indexer stall.
//
// Production symptom (several chains indexing at the head): chain 1 detects a
// reorg and rolls back; while the reprocessing batch is still in flight it detects
// the reorg AGAIN, producing this exact log sequence
//
//   Blockchain reorg detected. Initiating indexer rollback.   (reorg #1)
//   Started rollback on reorg
//   Finished rollback on reorg
//   Blockchain reorg detected. Initiating indexer rollback.   (reorg #2, same block/hashes)
//   Waiting for batch to finish processing before executing rollback
//   Finished processing batch before rollback, actioning rollback
//   Started rollback on reorg
//   Finished rollback on reorg
//
// after which chain 1 makes no further progress until the pod is restarted.
//
// This test drives that exact sequence through the MockIndexer and asserts the
// orchestrator reaches the parked-rollback state (rollbackState = FoundReorgDepth
// while currentlyProcessingBatch = true) — the "Waiting for batch to finish
// processing before executing rollback" limbo. See the block comment at the end
// for the two ways this limbo turns into the permanent, restart-only stall.

describe("Reorg rollback stall (v3.0.0)", () => {
  let rollbackStateTag = (indexerMock: MockIndexer.Indexer.t) =>
    switch indexerMock.dangerouslyGetState().rollbackState {
    | NoRollback => "NoRollback"
    | ReorgDetected(_) => "ReorgDetected"
    | FindingReorgDepth => "FindingReorgDepth"
    | FoundReorgDepth(_) => "FoundReorgDepth"
    | RollbackReady(_) => "RollbackReady"
    }

  Async.it(
    "parks the rollback ('Waiting for batch...') when a reorg is re-detected mid reprocessing batch",
    async t => {
      let sourceMock1 = MockIndexer.Source.make(
        [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes],
        ~chain=#1337,
      )
      let sourceMock2 = MockIndexer.Source.make(
        [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes],
        ~chain=#100,
      )
      let indexerMock = await MockIndexer.Indexer.make(
        ~chains=[
          {chain: #1337, sourceConfig: Config.CustomSources([sourceMock1.source])},
          {chain: #100, sourceConfig: Config.CustomSources([sourceMock2.source])},
        ],
      )
      await Utils.delay(0)

      let _ = await Promise.all2((
        MockIndexer.Helper.initialEnterReorgThreshold(~t, ~indexerMock, ~sourceMock=sourceMock1),
        MockIndexer.Helper.initialEnterReorgThreshold(~t, ~indexerMock, ~sourceMock=sourceMock2),
      ))

      // Commit progress on both chains at block 102.
      sourceMock1.resolveGetItemsOrThrow(
        [
          {
            blockNumber: 102,
            logIndex: 0,
            handler: async ({context}) => context.\"SimpleEntity".set({id: "1", value: "c1-102"}),
          },
        ],
        ~latestFetchedBlockNumber=102,
        ~resolveAt=#first,
      )
      sourceMock2.resolveGetItemsOrThrow(
        [
          {
            blockNumber: 102,
            logIndex: 0,
            handler: async ({context}) => context.\"SimpleEntity".set({id: "2", value: "c2-102"}),
          },
        ],
        ~latestFetchedBlockNumber=102,
        ~resolveAt=#first,
      )
      await indexerMock.getBatchWritePromise()

      // === REORG #1 on chain 1337 (block 102) ===
      sourceMock1.resolveGetItemsOrThrow(
        [],
        ~prevRangeLastBlock={blockNumber: 102, blockHash: "0x102-reorged"},
        ~resolveAt=#first,
      )
      await Utils.delay(0)
      await Utils.delay(0)
      t.expect(
        sourceMock1.getBlockHashesCalls,
        ~message="reorg #1 looks for the rollback depth (blocks below 102 in threshold)",
      ).toEqual([[100]])
      sourceMock1.resolveGetBlockHashes([{blockNumber: 100, blockHash: "0x100", blockTimestamp: 100}])
      sourceMock2.resolveGetItemsOrThrow([], ~resolveAt=#all)

      await indexerMock.getRollbackReadyPromise()
      // After rollback #1, chain 1337 re-fetches from the rolled-back block 101.
      // (rollbackState stays RollbackReady until that re-fetched event is
      // reprocessed — the reprocessing IS the gated batch below.)
      let drained = ref(0)
      while (
        drained.contents < 200 &&
        !(sourceMock1.getItemsOrThrowCalls->Array.some(c => c.payload["fromBlock"] == 101))
      ) {
        await Utils.delay(1)
        drained := drained.contents + 1
      }
      t.expect(
        sourceMock1.getItemsOrThrowCalls->Array.map(c => c.payload),
        ~message="rollback #1 settled; chain 1337 re-fetches from block 101",
      ).toEqual([{"fromBlock": 101, "toBlock": None, "retry": 0, "p": "0"}])

      // Reprocess a real event at block 101 whose handler blocks on a gate, so the
      // batch is still in flight when the second reorg lands.
      let releaseGate = ref(() => ())
      let gate = Promise.make((resolve, _reject) => releaseGate := () => resolve())
      sourceMock1.resolveGetItemsOrThrow(
        [
          {
            blockNumber: 101,
            logIndex: 0,
            handler: async ({context}) => {
              context.\"SimpleEntity".set({id: "1", value: "c1-101-reprocessed"})
              await gate
            },
          },
        ],
        ~latestFetchedBlockNumber=101,
        ~resolveAt=#first,
      )

      // Wait until the batch is genuinely in flight and chain 1337 launched its
      // next fetch from block 102.
      let waited = ref(0)
      while (
        waited.contents < 100 &&
        !(
          indexerMock.dangerouslyGetState().currentlyProcessingBatch &&
          sourceMock1.getItemsOrThrowCalls->Array.some(c => c.payload["fromBlock"] == 102)
        )
      ) {
        await Utils.delay(1)
        waited := waited.contents + 1
      }
      t.expect(
        indexerMock.dangerouslyGetState().currentlyProcessingBatch,
        ~message="the block-101 reprocessing batch is in flight when the second reorg lands",
      ).toEqual(true)

      // === REORG #2 on chain 1337 (block 101), while the batch is still in flight ===
      sourceMock1.resolveGetItemsOrThrow(
        [],
        ~prevRangeLastBlock={blockNumber: 101, blockHash: "0x101-reorged"},
        ~resolveAt=#first,
      )
      await Utils.delay(0)
      await Utils.delay(0)
      sourceMock1.resolveGetBlockHashes([{blockNumber: 100, blockHash: "0x100", blockTimestamp: 100}])
      await Utils.delay(0)
      await Utils.delay(0)

      // THE LIMBO: rollback #2 is parked waiting for the in-flight batch — this is
      // the production "Waiting for batch to finish processing before executing
      // rollback" state, reached deterministically here.
      t.expect(
        (rollbackStateTag(indexerMock), indexerMock.dangerouslyGetState().currentlyProcessingBatch),
        ~message="reorg re-detected mid-batch parks the rollback at FoundReorgDepth",
      ).toEqual(("FoundReorgDepth", true))
      t.expect(
        GlobalState.isPreparingRollback(indexerMock.dangerouslyGetState()),
        ~message="while parked the indexer is preparing a rollback, so all fetching/processing is suspended",
      ).toEqual(true)

      // Releasing the batch lets the parked rollback execute ("Finished processing
      // batch before rollback, actioning rollback" -> second rollback).
      releaseGate.contents()
      let ran = ref(0)
      while (
        ran.contents < 200 &&
        (rollbackStateTag(indexerMock) == "FoundReorgDepth" ||
          rollbackStateTag(indexerMock) == "FindingReorgDepth" ||
          rollbackStateTag(indexerMock) == "ReorgDetected")
      ) {
        try sourceMock1.resolveGetBlockHashes([
          {blockNumber: 100, blockHash: "0x100", blockTimestamp: 100},
        ]) catch {
        | _ => ()
        }
        await Utils.delay(1)
        ran := ran.contents + 1
      }

      // Once the batch drains, the parked rollback runs (it is no longer stuck at
      // FoundReorgDepth). On this clean, single-partition, fully-driven path the
      // second rollback's progress diff stays non-negative so the indexer recovers;
      // getErrors() therefore holds the fatal counter error only in the timing
      // windows where that diff goes negative (see note 1 below).
      t.expect(
        rollbackStateTag(indexerMock) != "FoundReorgDepth",
        ~message="the parked rollback ran once the batch drained",
      ).toEqual(true)

      // --- How this limbo becomes the permanent, restart-only stall ---
      //
      // The parked-rollback path above is where the production indexer wedges. Two
      // failure modes were observed downstream of this exact state, both matching
      // "no getHeight, no queries, no items processed until the pod is restarted":
      //
      // 1) Fatal Prometheus error (crash). When the second rollback runs, its
      //    `getRollbackProgressDiff` can return a NEGATIVE events-processed diff
      //    (the non-reorg chain's events are subtracted a second time — the same
      //    family as the "negative counter" regression, but here reached via the
      //    reorg-detected-while-a-batch-is-processing path that the existing
      //    regression tests do not cover). That negative flows into
      //    `Prometheus.RollbackSuccess.increment` ->
      //    `envio_rollback_events.incMany(<negative>)`, and prom-client throws
      //    "It is not possible to decrease a counter". The throw happens right
      //    AFTER "Finished rollback on reorg" is logged (Prometheus.RollbackSuccess
      //    is incremented at the very end of the rollback), which is exactly where
      //    the production log goes silent. The exception reaches the
      //    GlobalStateManager error boundary, which calls process.exit(Failure) ->
      //    the crash requiring a pod restart.
      //
      // 2) Fetch-state hole (deadlock). With more than one fetch partition on the
      //    chain (dynamic contracts) or chunked queries, the double rollback can
      //    leave one partition's fetch frontier behind the buffered items of
      //    another. `getReadyItemsCount` is bounded by `bufferBlockNumber` (the min
      //    partition frontier), so those buffered items (the reported "50 items in
      //    buffer") can never be processed and the lagging partition returns
      //    NothingToQuery — no getHeight, no getItems — on that one chain while the
      //    others keep going.
    },
  )
})
