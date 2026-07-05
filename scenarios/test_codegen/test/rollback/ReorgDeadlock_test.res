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
// for how this limbo turns into the permanent, restart-only per-chain stall, and
// FetchState_test.res ("Reorg-stranded pending query wedges a partition") for a
// deterministic reproduction of the stalled fetch state itself.

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
      // FoundReorgDepth).
      t.expect(
        rollbackStateTag(indexerMock) != "FoundReorgDepth",
        ~message="the parked rollback ran once the batch drained",
      ).toEqual(true)

      // --- How this limbo becomes the permanent, restart-only per-chain stall ---
      //
      // The parked-rollback path above is where the production indexer wedges the
      // reorged chain, matching "no getHeight, no queries, no items processed until
      // the pod is restarted" while the other chains keep progressing.
      //
      // The reorg that re-fires here bumps the state epoch (GlobalState.id) and
      // resets in-flight queries. Any query whose response comes back at the old
      // epoch is routed to `invalidatedActionReducer` and discarded ("Invalidated
      // action discarded"), so `FetchState.handleQueryResult` never runs for it. In
      // v3.0.0 `FetchState.getNextQuery` decides a partition is busy purely from
      // `mutPendingQueries->Utils.Array.notEmpty`, with no notion of which epoch
      // launched the query — so a partition left holding such a discarded query is
      // treated as permanently fetching: it returns NothingToQuery on every tick
      // and never queries or checks the head again.
      //
      // With a second fetch partition on the chain (dynamic contracts or chunked
      // queries) the sibling keeps fetching ahead, but `getReadyItemsCount` is
      // bounded by `bufferBlockNumber` (the min partition frontier), so its buffered
      // items — the reported "~50 items in buffer" — can never be processed past the
      // wedged partition's frontier. FetchState_test.res reproduces exactly this
      // stalled fetch state deterministically.
      //
      // The fix (dz/find-reorg-depth-concurrently) makes getNextQuery epoch-aware:
      // partitions carry `status.fetchingStateId` and `checkIsFetchingPartition`
      // counts a partition as busy only while `stateId <= fetchingStateId`, so a
      // query left over from an older epoch no longer blocks re-querying.
    },
  )
})
