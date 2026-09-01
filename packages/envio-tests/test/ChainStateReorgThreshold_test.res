open Vitest

// The production threshold arithmetic: ChainState derives merge/read/prune
// boundaries from (knownHeight, maxReorgDepth), where maxReorgDepth is the
// resumed-from-DB value and may differ from the config after a restart.
describe("ChainState reorg threshold", () => {
  let baseChainConfig = TestConfig.default.chainMap->ChainMap.values->Utils.Array.firstUnsafe

  let makeChainState = (~knownHeight, ~maxReorgDepth, ~scannedHashes) => {
    let addressStore = AddressStore.make(~ecosystem=Evm, ~shouldChecksum=false, ~contracts=[])
    let base = FetchState.make(
      ~onEventRegistrations=[],
      ~addressStore,
      ~addressRows=AddressRows.emptySeedRows(),
      ~onBlockRegistrations=[
        {
          Internal.index: 0,
          name: "reorg-threshold-test",
          chainId: baseChainConfig.id,
          startBlock: None,
          endBlock: None,
          interval: 1,
          handler: "mock onBlock handler"->(
            Utils.magic: string => Internal.onBlockArgs => promise<unit>
          ),
        },
      ],
      ~startBlock=0,
      ~endBlock=None,
      ~maxAddrInPartition=3,
      ~maxOnBlockBufferSize=10000,
      ~chainId=baseChainConfig.id,
      ~knownHeight=0,
    )
    let blockStore = BlockStore.make(~ecosystem=Svm, ~shouldChecksum=false)
    let seedPage = BlockStore.fromJs(
      scannedHashes->Array.map(((blockNumber, blockHash)): BlockStore.inputBlock => {
        blockNumber,
        blockHash,
      }),
      ~ecosystem=Svm,
      ~shouldChecksum=false,
    )
    switch blockStore->BlockStore.merge(seedPage, ~fromBlock=0, ~reportOnly=false) {
    | Null.Value(_) => JsError.throwWithMessage("Unexpected reorg detected in test setup")
    | Null.Null => ()
    }
    let fetchState = {...base, FetchState.knownHeight}
    let mockSource = MockSource.make([], ~chainId=1)
    let cs = ChainState.make(
      ~chainConfig=baseChainConfig,
      ~fetchState,
      ~addressStore,
      ~sourceManager=SourceManager.make(~sources=[mockSource.source], ~isRealtime=false),
      ~shouldRollbackOnReorg=true,
      ~maxReorgDepth,
      ~committedProgressBlockNumber=-1,
      ~blockStore,
      ~logger=Logging.getLogger(),
    )
    (cs, fetchState)
  }

  let scannedHashes = [(1, "0x1"), (50, "0x50"), (300, "0x300"), (500, "0x500")]

  it("getReorgThresholdBlockNumbersBelow derives the threshold from knownHeight and depth", t => {
    let thresholdBlocks = (~knownHeight, ~maxReorgDepth) => {
      let (cs, _) = makeChainState(~knownHeight, ~maxReorgDepth, ~scannedHashes)
      cs->ChainState.getReorgThresholdBlockNumbersBelow(~blockNumber=501)
    }

    t.expect({
      "sameDepth": thresholdBlocks(~knownHeight=500, ~maxReorgDepth=200),
      // The store was seeded with checkpoints scanned under depth 200; resuming
      // with a smaller or larger depth must re-derive the threshold, not reuse
      // the one the checkpoints were saved with.
      "shrunkDepth": thresholdBlocks(~knownHeight=500, ~maxReorgDepth=199),
      "grownDepth": thresholdBlocks(~knownHeight=500, ~maxReorgDepth=450),
      "clampedToZero": thresholdBlocks(~knownHeight=100, ~maxReorgDepth=200),
    }).toEqual({
      "sameDepth": [300, 500],
      "shrunkDepth": [500],
      "grownDepth": [50, 300, 500],
      "clampedToZero": [1, 50, 300, 500],
    })
  })

  it("registerReorgGuard compares hashes only at or above knownHeight - maxReorgDepth", t => {
    let registerConflictAt300 = (~knownHeight) => {
      let (cs, _) = makeChainState(~knownHeight=500, ~maxReorgDepth=200, ~scannedHashes)
      cs->ChainState.registerReorgGuard(
        ~blockStore=BlockStore.fromJs(
          [{BlockStore.blockNumber: 300, blockHash: "0x300-different"}],
          ~ecosystem=Svm,
          ~shouldChecksum=false,
        ),
        ~knownHeight,
      )
    }

    t.expect(
      registerConflictAt300(~knownHeight=500),
      ~message="Block 300 is exactly at the threshold, so the conflict is a reorg",
    ).toEqual(
      ReorgDetection.ReorgDetected({
        scannedBlock: {blockNumber: 300, blockHash: "0x300"},
        receivedBlock: {blockNumber: 300, blockHash: "0x300-different"},
      }),
    )
    t.expect(
      registerConflictAt300(~knownHeight=501),
      ~message="One block later 300 leaves the threshold and the conflict is ignored",
    ).toEqual(ReorgDetection.NoReorg)
  })

  it("applyBatchProgress prunes processed blocks but keeps in-threshold hashes", t => {
    let (cs, fetchState) = makeChainState(~knownHeight=500, ~maxReorgDepth=200, ~scannedHashes)
    let progressedChainsById = Dict.make()
    progressedChainsById->ChainId.Dict.set(
      baseChainConfig.id,
      (
        {
          batchSize: 0,
          progressBlockNumber: 500,
          sourceBlockNumber: 500,
          totalEventsProcessed: 0.,
          fetchState,
          isProgressAtHeadWhenBatchCreated: false,
        }: Batch.chainAfterBatch
      ),
    )
    let batch: Batch.t = {
      totalBatchSize: 0,
      items: [],
      progressedChainsById,
      isInReorgThreshold: true,
      checkpointIds: [],
      checkpointChainIds: [],
      checkpointBlockNumbers: [],
      checkpointBlockHashes: [],
      checkpointEventsProcessed: [],
      registeredAddresses: [],
    }

    cs->ChainState.applyBatchProgress(~batch, ~blockTimestampName="timestamp")

    t.expect(
      cs
      ->ChainState.blockStore
      ->BlockStore.getHashedBlockNumbers(~fromBlock=0, ~belowBlock=1000),
      ~message="Processed blocks below knownHeight - maxReorgDepth lose their hashes; in-threshold ones stay",
    ).toEqual([300, 500])
  })
})
