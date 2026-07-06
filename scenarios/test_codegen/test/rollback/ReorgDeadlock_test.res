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

      // --- Hypothesized mechanism for the permanent, restart-only per-chain stall ---
      //
      // The parked-rollback path above is the best candidate for where the
      // production indexer wedges a chain, matching "no getHeight, no queries, no
      // items processed until the pod is restarted" while other chains progress.
      //
      // The mechanism (PROVEN reachable as a code path, NOT proven to cause a
      // permanent stall — see the caveat below): a reorg bumps the state epoch
      // (GlobalState.id) and resets in-flight queries. A query whose response
      // comes back at the old epoch is routed to `invalidatedActionReducer` and
      // discarded ("Invalidated action discarded"), so `FetchState.handleQueryResult`
      // never runs for it. v3.0.0's `FetchState.getNextQuery` decides a partition is
      // busy purely from `mutPendingQueries->Utils.Array.notEmpty`, with no notion
      // of which epoch launched the query — so IF a partition were left holding
      // such a discarded query, it would be treated as permanently fetching:
      // NothingToQuery on every tick, never querying or checking the head again.
      // With a second fetch partition on the chain (dynamic contracts or chunked
      // queries), the sibling would keep fetching ahead while `getReadyItemsCount`
      // (bounded by `bufferBlockNumber`, the min partition frontier) leaves its
      // buffered items — the reported "~50 items in buffer" — stuck behind the
      // wedged partition. FetchState_test.res ("Reorg-stranded pending query
      // wedges a partition") reproduces that consequence deterministically, GIVEN
      // such an orphan.
      //
      // CAVEAT: the two experiments below drive this exact epoch-race through the
      // real orchestration — first cross-chain (a reorg on chain A racing an
      // in-flight response on bystander chain B), then same-chain (a reorg on one
      // partition racing an in-flight response on a second, dynamic-contract
      // partition of the SAME chain — the topology that actually matches the
      // "~50 items in buffer" symptom). Both confirm the discard happens exactly
      // as described (pending entry wiped, response later silently dropped,
      // latestFetchedBlock never advances for the discarded response). In BOTH
      // cases the affected partition does NOT stay stranded — the rollback's
      // re-fetch (cross-chain: every chain rolls back in lockstep; same-chain:
      // FetchState.rollback recreates/adjusts every partition on the chain)
      // re-dispatches a fresh query as a side effect, and it recovers immediately
      // once answered. So the orphaning step is real and reachable in the exact
      // topology of the production symptom, but every interleaving constructed so
      // far — cross-chain and same-chain alike — self-heals; whether a partition
      // can actually stay wedged in production remains unconfirmed. The fix
      // (dz/find-reorg-depth-concurrently) closes the mechanism regardless, by
      // making getNextQuery epoch-aware: partitions carry `status.fetchingStateId`,
      // and `checkIsFetchingPartition` counts a partition as busy only while
      // `stateId <= fetchingStateId`.
    },
  )
})

// EXPERIMENT (negative result): tries to force the epoch-race described above
// through the *real* GlobalState orchestration (not by hand-constructing
// FetchState), to check whether it produces a permanent per-chain stall or
// whether v3.0.0's defenses — `resetPendingQueries` (wipes every in-flight query
// on every chain, the instant any reorg is detected), the `isPreparingRollback`
// dispatch gate, and the shared cross-chain rollback re-fetch — heal it.
//
// The race: chain B's query response is validated (no reorg) in the same
// microtask-drain window as chain A's reorg-detecting response. At that instant
// chain B's pendingQuery entry is still untouched (fetchedBlock: None) —
// FetchState.handleQueryResult for it hasn't run yet, that only happens later via
// the ProcessPartitionQueryResponse -> SubmitPartitionQueryResponse task chain.
// resetPendingQueries's sweep (triggered by chain A's reorg) does strip chain B's
// entry before that task chain completes, and chain B's own completion later
// dispatches with a stale epoch and is silently discarded by
// invalidatedActionReducer, exactly as hypothesized.
//
// But this does NOT strand chain B: the rollback rolls every chain's fetchState
// back in lockstep (to stay timestamp-consistent across chains, not just the
// reorged one), which re-dispatches a fresh query for chain B as a side effect.
// Once that query is answered, chain B resumes normal progress. An earlier
// version of this test concluded chain B was permanently stuck — that was a bug
// in the test itself (it waited for the call *count* to grow instead of
// resolving the live pending call the rollback had already created), not a real
// indexer stall. Left in as a regression test: this specific race is safe.
describe("Experiment: does a bystander chain's in-flight query survive a concurrent reorg?", () => {
  let rollbackStateTag = (indexerMock: MockIndexer.Indexer.t) =>
    switch indexerMock.dangerouslyGetState().rollbackState {
    | NoRollback => "NoRollback"
    | ReorgDetected(_) => "ReorgDetected"
    | FindingReorgDepth => "FindingReorgDepth"
    | FoundReorgDepth(_) => "FoundReorgDepth"
    | RollbackReady(_) => "RollbackReady"
    }

  Async.it(
    "races a chain's normal query response against another chain's reorg-detecting response",
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

      // Commit progress on both chains at block 102 (records block 102's hash in
      // ReorgDetection for chain 1337, so a later mismatched response at the same
      // block number is what will reveal the reorg).
      sourceMock1.resolveGetItemsOrThrow(
        [],
        ~latestFetchedBlockNumber=102,
        ~resolveAt=#first,
      )
      sourceMock2.resolveGetItemsOrThrow(
        [],
        ~latestFetchedBlockNumber=102,
        ~resolveAt=#first,
      )
      await indexerMock.getBatchWritePromise()

      // Both chains have now dispatched their next query (fromBlock=103). Grab
      // chain 100's pending call — this is the "innocent bystander" query whose
      // response we will land in the exact same microtask-drain window as chain
      // 1337's reorg-detecting response.
      let chain100Call =
        sourceMock2.getItemsOrThrowCalls
        ->Array.find(c => c.payload["fromBlock"] == 103)
        ->Option.getOrThrow(~message="chain 100 should have a fromBlock=103 query pending")

      let chain100 = ChainMap.Chain.makeUnsafe(~chainId=100)
      let getChain100PendingQueries = () =>
        (
          (
            indexerMock.dangerouslyGetState().chainManager.chainFetchers->ChainMap.get(chain100)
          ).fetchState.optimizedPartitions.entities->Dict.getUnsafe("0")
        ).mutPendingQueries

      t.expect(
        getChain100PendingQueries()->Array.length,
        ~message="chain 100's fromBlock=103 query is genuinely in flight before the race",
      ).toEqual(1)

      // THE RACE: resolve chain 100's normal response and chain 1337's
      // reorg-detecting response back-to-back, with NO await between them, so
      // both continuations run in the same microtask-drain window — before
      // either one's ProcessPartitionQueryResponse (setImmediate-scheduled) task
      // has a chance to run.
      chain100Call.resolve([], ~latestFetchedBlockNumber=103)
      sourceMock1.resolveGetItemsOrThrow(
        [],
        ~prevRangeLastBlock={blockNumber: 102, blockHash: "0x102-reorged"},
        ~resolveAt=#first,
      )

      await Utils.delay(0)
      await Utils.delay(0)

      // Did chain 1337's reorg-triggered resetPendingQueries strip chain 100's
      // still-unfinalized pendingQuery entry? (v3.0.0's resetPendingQueries sweeps
      // every chain unconditionally, so this is expected to be stripped.)
      t.expect(
        getChain100PendingQueries()->Array.length,
        ~message="chain 100's in-flight entry is wiped by the reorg's resetPendingQueries sweep",
      ).toEqual(0)

      // Let rollback #1 settle fully.
      t.expect(
        sourceMock1.getBlockHashesCalls,
        ~message="reorg looks for the rollback depth",
      ).toEqual([[100]])
      sourceMock1.resolveGetBlockHashes([{blockNumber: 100, blockHash: "0x100", blockTimestamp: 100}])
      await indexerMock.getRollbackReadyPromise()

      // Drain chain 1337's post-rollback re-fetch so the indexer is fully settled.
      let drained = ref(0)
      while (
        drained.contents < 200 &&
        !(sourceMock1.getItemsOrThrowCalls->Array.some(c => c.payload["fromBlock"] == 101))
      ) {
        await Utils.delay(1)
        drained := drained.contents + 1
      }
      sourceMock1.resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=101, ~resolveAt=#first)
      await Utils.delay(0)
      await Utils.delay(0)

      // Diagnostics: confirm the indexer as a whole is NOT still preparing a
      // rollback (i.e. this isn't just "chain 100 correctly waiting its turn") —
      // and inspect chain 100's own fetchState directly.
      t.expect(
        (
          indexerMock.dangerouslyGetState()->GlobalState.isPreparingRollback,
          rollbackStateTag(indexerMock),
        ),
        ~message="the indexer is fully settled (not preparing a rollback) by the time we check on chain 100",
      ).toEqual((false, "RollbackReady"))

      let chain100FetchStateSnapshot = () => {
        let cf = indexerMock.dangerouslyGetState().chainManager.chainFetchers->ChainMap.get(chain100)
        let p = cf.fetchState.optimizedPartitions.entities->Dict.getUnsafe("0")
        (p.mutPendingQueries->Array.length, p.latestFetchedBlock.blockNumber, cf.fetchState.knownHeight)
      }
      // Chain 100 never reorged itself, but the shared rollback rolled every
      // chain's fetchState back in lockstep (to stay timestamp-consistent across
      // chains) — its latestFetchedBlock moved from 102 down to 101, and it has
      // ONE pending query outstanding (the rollback-driven re-fetch). This is a
      // real, live, unresolved getItemsOrThrow call sitting in sourceMock2 that
      // the test must actually resolve to find out if chain 100 recovers — merely
      // waiting for the call *count* to grow (as the first version of this
      // experiment did) is a false negative: the count never grows because
      // nothing ever answers the pending call.
      t.expect(
        chain100FetchStateSnapshot(),
        ~message="chain 100's partition after the shared rollback: one pending re-fetch query, rolled back to block 101",
      ).toEqual((1, 101, 300))

      // THE VERDICT: drive chain 100 forward for several more rounds by actually
      // answering its pending calls (both getItemsOrThrow and getHeightOrThrow),
      // and confirm its latestFetchedBlock keeps advancing — i.e. it behaves like
      // a perfectly healthy chain once given responses, meaning the earlier
      // "stall" was this test failing to drive it, not the indexer being wedged.
      let advanced = ref(false)
      let round = ref(0)
      while (!advanced.contents && round.contents < 50) {
        switch sourceMock2.getItemsOrThrowCalls->Array.get(0) {
        | Some(call) =>
          let fromBlock = call.payload["fromBlock"]
          call.resolve([], ~latestFetchedBlockNumber=fromBlock + 5)
        | None => ()
        }
        if sourceMock2.getHeightOrThrowCalls->Array.length > 0 {
          sourceMock2.resolveGetHeightOrThrow(300)
        }
        await Utils.delay(1)
        let (_, latestFetchedBlockNumber, _) = chain100FetchStateSnapshot()
        if latestFetchedBlockNumber > 101 {
          advanced := true
        }
        round := round.contents + 1
      }

      t.expect(
        advanced.contents,
        ~message="once its pending call is actually answered, chain 100 advances normally — the earlier stuck-looking state was a live, resolvable in-flight query, not a permanent orphan",
      ).toEqual(true)
    },
  )
})

// EXPERIMENT 2: same-chain, two-partition version of the race above. This is the
// topology that actually matches the production symptom (one reorging chain,
// buffered items behind a wedged partition) — the cross-chain experiment above
// only ruled out one chain stranding a *different* chain, not a chain stranding
// itself via a second fetch partition (dynamic contracts).
//
// Registers a dynamic contract early (registrationBlock=50, well inside the
// reorg threshold) so the resulting partition SURVIVES the rollback (kept +
// pending queries adjusted) instead of being deleted as "didn't exist yet at the
// rollback target" — deletion would trivially "fix" a stranded entry by throwing
// the whole partition away, which would hide the bug rather than test it.
describe("Experiment 2: does a chain strand its own second partition via a concurrent reorg?", () => {
  let rollbackStateTag = (indexerMock: MockIndexer.Indexer.t) =>
    switch indexerMock.dangerouslyGetState().rollbackState {
    | NoRollback => "NoRollback"
    | ReorgDetected(_) => "ReorgDetected"
    | FindingReorgDepth => "FindingReorgDepth"
    | FoundReorgDepth(_) => "FoundReorgDepth"
    | RollbackReady(_) => "RollbackReady"
    }

  Async.it(
    "races partition 2's normal response against partition 0's reorg-detecting response on the same chain",
    async t => {
      let sourceMock1 = MockIndexer.Source.make(
        [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes],
        ~chain=#1337,
      )
      let indexerMock = await MockIndexer.Indexer.make(
        ~chains=[{chain: #1337, sourceConfig: Config.CustomSources([sourceMock1.source])}],
      )
      await Utils.delay(0)

      t.expect(
        sourceMock1.getHeightOrThrowCalls->Array.length,
        ~message="initial height check",
      ).toEqual(1)
      sourceMock1.resolveGetHeightOrThrow(300)
      await Utils.delay(0)
      await Utils.delay(0)

      t.expect(
        sourceMock1.getItemsOrThrowCalls->Array.map(c => c.payload),
        ~message="requests items until reorg threshold",
      ).toEqual([{"fromBlock": 1, "toBlock": Some(100), "retry": 0, "p": "0"}])

      // Register a dynamic contract at block 50 (well inside the threshold) while
      // committing partition "0" through block 100 — creates partition "2".
      sourceMock1.resolveGetItemsOrThrow(
        [
          {
            blockNumber: 50,
            logIndex: 0,
            contractRegister: async ({context}) => {
              context.chain.\"SimpleNft".add(Envio.TestHelpers.Addresses.mockAddresses->Array.getUnsafe(0))
            },
            handler: async ({context}) => context.\"SimpleEntity".set({id: "dc", value: "registered"}),
          },
        ],
        ~latestFetchedBlockNumber=100,
      )
      await indexerMock.getBatchWritePromise()

      // Both partitions now have their own pending query. Bring partition "2"
      // (starts from its registration block, 50) up to the same point as
      // partition "0" (which continues from 101).
      let findPartitionCall = partitionId =>
        sourceMock1.getItemsOrThrowCalls
        ->Array.find(c => c.payload["p"] == partitionId)
        ->Option.getOrThrow(~message=`no pending call for partition ${partitionId}`)

      findPartitionCall("2").resolve([], ~latestFetchedBlockNumber=100)
      await Utils.delay(0)
      await Utils.delay(0)

      // Commit both partitions through block 102 so there is recorded reorg
      // checkpoint data at 102 for the race to reveal a mismatch against.
      findPartitionCall("0").resolve([], ~latestFetchedBlockNumber=102)
      await Utils.delay(0)
      await Utils.delay(0)
      findPartitionCall("2").resolve([], ~latestFetchedBlockNumber=102)
      await indexerMock.getBatchWritePromise()

      let getPartitionState = partitionId => {
        let cf =
          (indexerMock.dangerouslyGetState().chainManager.chainFetchers->ChainMap.get(
            ChainMap.Chain.makeUnsafe(~chainId=1337),
          )).fetchState
        let p = cf.optimizedPartitions.entities->Dict.getUnsafe(partitionId)
        (p.mutPendingQueries->Array.length, p.latestFetchedBlock.blockNumber, cf.knownHeight)
      }

      t.expect(
        getPartitionState("2")->(((n, _, _)) => n),
        ~message="partition 2's fromBlock=103 query is genuinely in flight before the race",
      ).toEqual(1)

      // THE RACE: resolve partition 2's normal response and partition 0's
      // reorg-detecting response back-to-back, no await between — same
      // microtask-drain-window technique as experiment 1, but now both
      // partitions live on the SAME chainFetcher.fetchState.
      findPartitionCall("2").resolve([], ~latestFetchedBlockNumber=103)
      findPartitionCall("0").resolve(
        [],
        ~prevRangeLastBlock={blockNumber: 102, blockHash: "0x102-reorged"},
      )

      await Utils.delay(0)
      await Utils.delay(0)

      // Confirm this is a genuine strip-and-discard, not "just hasn't re-dispatched
      // yet": pending count is 0 AND latestFetchedBlock is still 102 (not 103) —
      // proving handleQueryResult never ran for partition 2's fromBlock=103
      // response (it was truly discarded), rather than partition 2 having
      // legitimately finished and simply not yet issued its next query.
      t.expect(
        getPartitionState("2")->(((n, lfb, _)) => (n, lfb)),
        ~message="partition 2's in-flight entry is wiped by the reorg's resetPendingQueries sweep, and its response was discarded (latestFetchedBlock never advanced to 103)",
      ).toEqual((0, 102))

      // Let the rollback settle fully.
      t.expect(
        sourceMock1.getBlockHashesCalls,
        ~message="reorg looks for the rollback depth",
      ).toEqual([[100]])
      sourceMock1.resolveGetBlockHashes([{blockNumber: 100, blockHash: "0x100", blockTimestamp: 100}])
      await indexerMock.getRollbackReadyPromise()

      t.expect(
        (indexerMock.dangerouslyGetState()->GlobalState.isPreparingRollback, rollbackStateTag(indexerMock)),
        ~message="the indexer is fully settled (not preparing a rollback) after the rollback",
      ).toEqual((false, "RollbackReady"))

      // Does partition 2 still exist (kept, since registrationBlock=50 <=
      // rollback target=100), and if so what state is it in?
      let partition2Exists =
        (indexerMock.dangerouslyGetState().chainManager.chainFetchers->ChainMap.get(
          ChainMap.Chain.makeUnsafe(~chainId=1337),
        )).fetchState.optimizedPartitions.entities
        ->Dict.get("2")
        ->Option.isSome
      t.expect(
        partition2Exists,
        ~message="partition 2 survives the rollback (registrationBlock=50 is within the rolled-back range)",
      ).toEqual(true)

      // THE VERDICT: drive every outstanding call on this chain (both partitions,
      // both getItemsOrThrow and getHeightOrThrow) for many rounds, and confirm
      // BOTH partitions' latestFetchedBlock keeps advancing — i.e. nothing on
      // this chain is permanently wedged.
      let round = ref(0)
      let bothAdvanced = ref(false)
      while (!bothAdvanced.contents && round.contents < 50) {
        sourceMock1.getItemsOrThrowCalls
        ->Utils.Array.copy
        ->Array.forEach(call => {
          let fromBlock = call.payload["fromBlock"]
          try call.resolve([], ~latestFetchedBlockNumber=fromBlock + 5) catch {
          | _ => ()
          }
        })
        if sourceMock1.getHeightOrThrowCalls->Array.length > 0 {
          try sourceMock1.resolveGetHeightOrThrow(300) catch {
          | _ => ()
          }
        }
        await Utils.delay(1)
        let (_, p0Block, _) = getPartitionState("0")
        let p2BlockOpt =
          (indexerMock.dangerouslyGetState().chainManager.chainFetchers->ChainMap.get(
            ChainMap.Chain.makeUnsafe(~chainId=1337),
          )).fetchState.optimizedPartitions.entities
          ->Dict.get("2")
          ->Option.map(p => p.latestFetchedBlock.blockNumber)
        if p0Block > 102 && p2BlockOpt->Option.getOr(0) > 103 {
          bothAdvanced := true
        }
        round := round.contents + 1
      }

      t.expect(
        bothAdvanced.contents,
        ~message="both partitions on the reorging chain keep advancing once answered — neither is permanently wedged by the same-chain race",
      ).toEqual(true)
    },
  )
})
