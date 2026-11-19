open Vitest

// The production threshold arithmetic: ChainState derives merge/read/prune
// boundaries from (knownHeight, maxReorgDepth), where maxReorgDepth is the
// resumed-from-DB value and may differ from the config after a restart.
describe("ChainState reorg threshold", () => {
  let baseChainConfig = TestConfig.default.chainMap->ChainMap.values->Utils.Array.firstUnsafe

  let makeChainState = (~knownHeight, ~maxReorgDepth, ~scannedHashes) => {
    let addressStore = AddressStore.make(~ecosystem=Evm, ~contracts=[])
    let base = TestFetchState.make(
      ~onNotice=ignore,
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
          blockFieldMask: None,
          handler: "mock onBlock handler"->(
            Utils.magic: string => Internal.onBlockArgs => promise<unit>
          ),
        },
      ],
      ~startBlock=0,
      ~endBlock=None,
      ~maxAddrInPartition=3,
      ~chainId=baseChainConfig.id,
      ~knownHeight=0,
    )
    let chainBuffer = TestChainBuffer.decodedBuffer(~onEventRegistrations=[], ~ecosystem=Svm)
    let seedPage = BufferPage.fromBlocks(
      scannedHashes->Array.map(((blockNumber, blockHash)): BufferPage.observedBlock => {
        blockNumber,
        blockHash,
      }),
      ~ecosystem=Svm,
    )
    switch (
      chainBuffer->ChainBuffer.mergePage(seedPage, ~reorgThreshold=0, ~reportOnly=false)
    ).mismatch {
    | Some(_) => JsError.throwWithMessage("Unexpected reorg detected in test setup")
    | None => ()
    }
    let fetchState = {...base, FetchState.knownHeight}
    let mockSource = MockSource.make([], ~chainId=1)
    let cs = ChainState.make(
      ~chainConfig=baseChainConfig,
      ~fetchState,
      ~chainBuffer,
      ~addressStore,
      ~sourceManager=SourceManager.make(
        ~logger=Logger.makeInMemory(),
        ~sources=[mockSource.source],
        ~isRealtime=false,
      ),
      ~shouldRollbackOnReorg=true,
      ~maxReorgDepth,
      ~committedProgressBlockNumber=-1,
      ~logger=Logger.makeInMemory(),
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

  it("mergePage compares hashes only at or above knownHeight - maxReorgDepth", t => {
    let registerConflictAt300 = (~knownHeight) => {
      let (cs, _) = makeChainState(~knownHeight=500, ~maxReorgDepth=200, ~scannedHashes)
      let (reorgResult, _) =
        cs->ChainState.mergePage(
          ~page=BufferPage.fromBlocks(
            [{BufferPage.blockNumber: 300, blockHash: "0x300-different"}],
            ~ecosystem=Svm,
          ),
          ~knownHeight,
        )
      reorgResult
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
    let (cs, _) = makeChainState(~knownHeight=500, ~maxReorgDepth=200, ~scannedHashes)
    let progressedChainsById = Dict.make()
    progressedChainsById->ChainId.Dict.set(
      baseChainConfig.id,
      (
        {
          chainId: baseChainConfig.id,
          batchSize: 0,
          progressBlockNumber: 500,
          progressBlockTime: None,
          sourceBlockNumber: 500,
          totalEventsProcessed: 0.,
          isProgressAtHeadWhenBatchCreated: false,
        }: Batch.chainAfterBatch
      ),
    )
    let batch: Batch.t = {
      totalBatchSize: 0,
      items: [],
      progressedChainsById,
      history: Dict.make(),
      checkpointIds: [],
      checkpointChainIds: [],
      checkpointBlockNumbers: [],
      checkpointBlockHashes: [],
      checkpointItemsCount: [],
      checkpointEventsProcessed: [],
      registeredAddresses: [],
    }

    cs->ChainState.applyBatchProgress(~batch, ~blockTimestampName="timestamp")

    t.expect(
      (
        cs
        ->ChainState.chainBuffer
        ->ChainBuffer.getBlockHashes(~fromBlock=0, ~belowBlock=1000)
      ).blockNumbers,
      ~message="Processed blocks below knownHeight - maxReorgDepth lose their hashes; in-threshold ones stay",
    ).toEqual([300, 500])
  })
})
