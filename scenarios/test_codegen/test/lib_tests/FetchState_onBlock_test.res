open Belt
open RescriptMocha

let chainId = 0

let mockAddress0 = TestHelpers.Addresses.mockAddresses[0]->Option.getExn

let getTimestamp = (~blockNumber) => blockNumber * 15

let getBlockData = (~blockNumber): FetchState.blockNumberAndTimestamp => {
  blockNumber,
  blockTimestamp: getTimestamp(~blockNumber),
}

let baseEventConfig = (Mock.evmEventConfig(
  ~id="0",
  ~contractName="Gravatar",
) :> Internal.eventConfig)

let makeOnBlockConfig = (
  ~name="testOnBlock",
  ~index=0,
  ~startBlock=None,
  ~endBlock=None,
  ~interval=1,
): Internal.onBlockConfig => {
  index,
  name,
  chainId,
  startBlock,
  endBlock,
  interval,
  handler: Utils.magic("mock handler"),
}

let makeInitialWithOnBlock = (~startBlock=0, ~onBlockConfigs) => {
  FetchState.make(
    ~eventConfigs=[baseEventConfig],
    ~contracts=[
      {
        Internal.address: mockAddress0,
        contractName: "Gravatar",
        startBlock,
        registrationBlock: None,
      },
    ],
    ~startBlock,
    ~endBlock=None,
    ~maxAddrInPartition=3,
    ~targetBufferSize=5000,
    ~chainId,
    ~onBlockConfigs?,
  )
}

let mockEvent = (~blockNumber, ~logIndex=0): Internal.item => Internal.Event({
  timestamp: blockNumber * 15,
  chain: ChainMap.Chain.makeUnsafe(~chainId),
  blockNumber,
  eventConfig: Utils.magic("Mock eventConfig in fetchstate test"),
  logIndex,
  event: Utils.magic("Mock event in fetchstate test"),
})

describe("FetchState onBlock functionality", () => {
  it("should add block items to queue when processing first batch with onBlock config", () => {
    // Create a fetch state with onBlock config
    let onBlockConfig = makeOnBlockConfig(~interval=2, ~startBlock=Some(0))
    let fetchState = makeInitialWithOnBlock(~onBlockConfigs=Some([onBlockConfig]))

    // Verify initial state - no items in queue
    Assert.equal(fetchState->FetchState.bufferSize, 0, ~message="Initial queue should be empty")

    // Simulate getting first batch of events by calling handleQueryResult
    // This should trigger the onBlock logic and add block items to the queue
    let updatedFetchState =
      fetchState
      ->FetchState.handleQueryResult(
        ~query={
          partitionId: "0",
          target: Head,
          selection: fetchState.normalSelection,
          addressesByContractName: Js.Dict.fromArray([("Gravatar", [mockAddress0])]),
          fromBlock: 0,
          indexingContracts: fetchState.indexingContracts,
        },
        ~latestFetchedBlock={blockNumber: 10, blockTimestamp: 10 * 15},
        ~newItems=[mockEvent(~blockNumber=5)],
      )
      ->Result.getExn

    // Get all (blockNumber, logIndex) tuples from the queue (including event items)
    let queue = updatedFetchState.buffer
    let blockNumberLogIndexTuples =
      queue->Array.map(item => (item->Internal.getItemBlockNumber, item->Internal.getItemLogIndex))

    // Should have block items for blocks 0, 2, 4, 6, 8, 10 (interval=2, startBlock=0) plus event at block 5
    // Expected in reverse order (latest to earliest): block items have logIndex=16777216, event has logIndex=0
    let expectedTuples = [
      (0, 16777216),
      (2, 16777216),
      (4, 16777216),
      (5, 0),
      (6, 16777216),
      (8, 16777216),
      (10, 16777216),
    ]

    // Check that we have the exact expected tuples
    Assert.deepEqual(
      blockNumberLogIndexTuples,
      expectedTuples,
      ~message="Should have correct block number and log index tuples",
    )
  })

  it("should respect onBlock startBlock configuration", () => {
    // Create onBlock config with startBlock = 5
    let onBlockConfig = makeOnBlockConfig(~interval=1, ~startBlock=Some(5))
    let fetchState = makeInitialWithOnBlock(~onBlockConfigs=Some([onBlockConfig]))

    // Process a batch that goes from block 0 to 10
    let updatedFetchState =
      fetchState
      ->FetchState.handleQueryResult(
        ~query={
          partitionId: "0",
          target: Head,
          selection: fetchState.normalSelection,
          addressesByContractName: Js.Dict.fromArray([("Gravatar", [mockAddress0])]),
          fromBlock: 0,
          indexingContracts: fetchState.indexingContracts,
        },
        ~latestFetchedBlock={blockNumber: 10, blockTimestamp: 10 * 15},
        ~newItems=[mockEvent(~blockNumber=5)],
      )
      ->Result.getExn

    // Get all (blockNumber, logIndex) tuples from the queue (including event items)
    let queue = updatedFetchState.buffer
    let blockNumberLogIndexTuples =
      queue->Array.map(item => (item->Internal.getItemBlockNumber, item->Internal.getItemLogIndex))

    // Should have block items starting from block 5 (startBlock=5, interval=1) plus event at block 5
    // The event at block 5 is NOT deduplicated with the block item at block 5
    // Expected in reverse order (latest to earliest): block items have higher priority than events at same block
    let expectedTuples = [
      (5, 0),
      (5, 16777216),
      (6, 16777216),
      (7, 16777216),
      (8, 16777216),
      (9, 16777216),
      (10, 16777216),
    ]

    // Check that we have the exact expected tuples
    Assert.deepEqual(
      blockNumberLogIndexTuples,
      expectedTuples,
      ~message="Should have correct block number and log index tuples",
    )
  })

  it("should respect onBlock endBlock configuration", () => {
    // Create onBlock config with endBlock = 8
    let onBlockConfig = makeOnBlockConfig(~interval=1, ~endBlock=Some(8))
    let fetchState = makeInitialWithOnBlock(~onBlockConfigs=Some([onBlockConfig]))

    // Process a batch that goes from block 0 to 10
    let updatedFetchState =
      fetchState
      ->FetchState.handleQueryResult(
        ~query={
          partitionId: "0",
          target: Head,
          selection: fetchState.normalSelection,
          addressesByContractName: Js.Dict.fromArray([("Gravatar", [mockAddress0])]),
          fromBlock: 0,
          indexingContracts: fetchState.indexingContracts,
        },
        ~latestFetchedBlock={blockNumber: 10, blockTimestamp: 10 * 15},
        ~newItems=[mockEvent(~blockNumber=5)],
      )
      ->Result.getExn

    // Get all (blockNumber, logIndex) tuples from the queue (including event items)
    let queue = updatedFetchState.buffer
    let blockNumberLogIndexTuples =
      queue->Array.map(item => (item->Internal.getItemBlockNumber, item->Internal.getItemLogIndex))

    // Should have block items that don't exceed endBlock=8 plus event at block 5
    // The event at block 5 is NOT deduplicated with the block item at block 5
    // Expected in reverse order (latest to earliest): block items have higher priority than events at same block
    let expectedTuples = [
      (0, 16777216),
      (1, 16777216),
      (2, 16777216),
      (3, 16777216),
      (4, 16777216),
      (5, 0),
      (5, 16777216),
      (6, 16777216),
      (7, 16777216),
      (8, 16777216),
    ]

    // Check that we have the exact expected tuples
    Assert.deepEqual(
      blockNumberLogIndexTuples,
      expectedTuples,
      ~message="Should have correct block number and log index tuples",
    )
  })

  it("should handle multiple onBlock configs with different intervals", () => {
    // Create two onBlock configs with different intervals
    let onBlockConfig1 = makeOnBlockConfig(~name="config1", ~index=0, ~interval=2)
    let onBlockConfig2 = makeOnBlockConfig(~name="config2", ~index=1, ~interval=3)
    let fetchState = makeInitialWithOnBlock(~onBlockConfigs=Some([onBlockConfig1, onBlockConfig2]))

    // Process a batch
    let updatedFetchState =
      fetchState
      ->FetchState.handleQueryResult(
        ~query={
          partitionId: "0",
          target: Head,
          selection: fetchState.normalSelection,
          addressesByContractName: Js.Dict.fromArray([("Gravatar", [mockAddress0])]),
          fromBlock: 0,
          indexingContracts: fetchState.indexingContracts,
        },
        ~latestFetchedBlock={blockNumber: 12, blockTimestamp: 12 * 15},
        ~newItems=[mockEvent(~blockNumber=5)],
      )
      ->Result.getExn

    // Get all (blockNumber, logIndex) tuples from the queue (including event items)
    let queue = updatedFetchState.buffer
    let blockNumberLogIndexTuples =
      queue->Array.map(item => (item->Internal.getItemBlockNumber, item->Internal.getItemLogIndex))

    // Should have block items for both configs plus event at block 5
    // Config1 (interval=2, index=0): blocks 0,2,4,6,8,10,12 with logIndex=16777216+0=16777216
    // Config2 (interval=3, index=1): blocks 0,3,6,9,12 with logIndex=16777216+1=16777217
    // Combined: 0(c1),0(c2),2(c1),3(c2),4(c1),5(event),6(c1),6(c2),8(c1),9(c2),10(c1),12(c1),12(c2)
    // Expected in reverse order (latest to earliest): [12(c2),12(c1),10(c1),9(c2),8(c1),6(c2),6(c1),5(event),4(c1),3(c2),2(c1),0(c2),0(c1)]
    let expectedTuples = [
      (0, 16777216),
      (0, 16777217),
      (2, 16777216),
      (3, 16777217),
      (4, 16777216),
      (5, 0),
      (6, 16777216),
      (6, 16777217),
      (8, 16777216),
      (9, 16777217),
      (10, 16777216),
      (12, 16777216),
      (12, 16777217),
    ]

    // Check that we have the exact expected tuples
    Assert.deepEqual(
      blockNumberLogIndexTuples,
      expectedTuples,
      ~message="Should have correct block number and log index tuples",
    )
  })

  it("should not add block items when onBlock configs are not provided", () => {
    // Create fetch state without onBlock configs
    let fetchState = makeInitialWithOnBlock(~onBlockConfigs=None)

    // Process a batch
    let updatedFetchState =
      fetchState
      ->FetchState.handleQueryResult(
        ~query={
          partitionId: "0",
          target: Head,
          selection: fetchState.normalSelection,
          addressesByContractName: Js.Dict.fromArray([("Gravatar", [mockAddress0])]),
          fromBlock: 0,
          indexingContracts: fetchState.indexingContracts,
        },
        ~latestFetchedBlock={blockNumber: 10, blockTimestamp: 10 * 15},
        ~newItems=[mockEvent(~blockNumber=5)],
      )
      ->Result.getExn

    // Verify that no block items were added when onBlock configs are not provided
    let queue = updatedFetchState.buffer
    let blockNumberLogIndexTuples =
      queue->Array.map(item => (item->Internal.getItemBlockNumber, item->Internal.getItemLogIndex))

    // Should have only the event item (block 5, logIndex 0)
    // Expected in reverse order (latest to earliest): [5]
    let expectedTuples = [(5, 0)]

    // Check that we have the exact expected tuples
    Assert.deepEqual(
      blockNumberLogIndexTuples,
      expectedTuples,
      ~message="Should have correct block number and log index tuples",
    )
  })
})
