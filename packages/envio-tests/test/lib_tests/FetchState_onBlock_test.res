open Vitest

let chainId = 0->ChainId.fromInt

// Spread into query literals so the common fields don't have to be repeated;
// every other field is overridden at the call site.
let defaultQuery: FetchState.query = {
  partitionId: "0",
  fromBlock: 0,
  toBlock: None,
  isChunk: false,
  itemsTarget: Some(0),
  itemsEst: 0,
  selection: {FetchState.dependsOnAddresses: false, onEventRegistrations: []},
  addresses: TestAddresses.setOf([]),
}

let mockAddress0 = Envio.TestHelpers.Addresses.mockAddresses[0]->Option.getOrThrow

let getTimestamp = (~blockNumber) => blockNumber * 15

let getBlockData = (~blockNumber): int => blockNumber

let baseEventConfig = (EventRegistration.evmOnEventRegistration(
  ~id="0",
  ~contractName="Gravatar",
) :> Internal.onEventRegistration)

let makeOnBlockRegistration = (
  ~name="testOnBlock",
  ~index=0,
  ~startBlock=None,
  ~endBlock=None,
  ~interval=1,
): Internal.onBlockRegistration => {
  index,
  name,
  chainId,
  startBlock,
  endBlock,
  interval,
  handler: Utils.magic("mock handler"),
}

let makeInitialWithOnBlock = (~startBlock=0, ~onBlockRegistrations) => {
  let onEventRegistrations = [baseEventConfig]
  let addresses = [
    {
      Internal.address: mockAddress0,
      contractName: "Gravatar",
      registrationBlock: -1,
    },
  ]
  let addressStore = TestAddresses.makeStore(~onEventRegistrations)
  FetchState.make(
    ~onEventRegistrations,
    ~addressStore,
    ~addresses,
    ~startBlock,
    ~endBlock=None,
    ~maxAddrInPartition=3,
    ~maxOnBlockBufferSize=5000,
    ~chainId,
    ~onBlockRegistrations?,
    ~knownHeight=0,
  )
}

let mockEvent = (~blockNumber, ~logIndex=0): Internal.item => Internal.Event({
  chainId: chainId,
  blockNumber,
  // Carries an `index` so the buffer's dedup key (blockNumber, logIndex, index)
  // resolves; the rest of the registration is unused by these tests.
  onEventRegistration: Utils.magic({"index": 0}),
  logIndex,
  transactionIndex: 0,
  payload: "Mock event in fetchstate test"->(Utils.magic: string => Internal.eventPayload),
})

// An item's position within its block: an event by log index, a block handler
// by registration, after every event of that block. Block items carry no log
// index — the item kind is what orders them.
let event = logIndex => `event:${logIndex->Int.toString}`
let blockHandler = index => `blockHandler:${index->Int.toString}`
let itemCoordinate = (item: Internal.item) =>
  switch item {
  | Internal.Event({blockNumber, logIndex}) => (blockNumber, event(logIndex))
  | Internal.Block({blockNumber, onBlockRegistration}) => (
      blockNumber,
      blockHandler(onBlockRegistration.index),
    )
  }

describe("FetchState onBlock functionality", () => {
  it("should add block items to queue when processing first batch with onBlock config", t => {
    // Create a fetch state with onBlock config
    let onBlockRegistration = makeOnBlockRegistration(~interval=2, ~startBlock=Some(0))
    let fetchState = makeInitialWithOnBlock(~onBlockRegistrations=Some([onBlockRegistration]))

    // Verify initial state - no items in queue
    t.expect(fetchState->FetchState.bufferSize, ~message="Initial queue should be empty").toBe(0)

    // Simulate getting first batch of events by calling handleQueryResult
    // This should trigger the onBlock logic and add block items to the queue
    let query: FetchState.query = {
      partitionId: "0",
      itemsTarget: Some(0),
      itemsEst: 0,
      toBlock: None,
      isChunk: false,
      selection: fetchState.normalSelection,
      addresses: TestAddresses.setOf([mockAddress0]),
      fromBlock: 0,
    }
    fetchState->FetchState.startFetchingQueries(~queries=[query])
    let updatedFetchState =
      fetchState->FetchState.handleQueryResult(
        ~query,
        ~latestFetchedBlock=10,
        ~newItems=[mockEvent(~blockNumber=5)],
      )

    // Get all (blockNumber, logIndex) tuples from the queue (including event items)
    let queue = updatedFetchState.buffer
    let blockNumberLogIndexTuples = queue->Array.map(itemCoordinate)

    // Should have block items for blocks 0, 2, 4, 6, 8, 10 (interval=2, startBlock=0) plus event at block 5
    // A block's events come first, then its block handlers.
    let expectedTuples = [
      (0, blockHandler(0)),
      (2, blockHandler(0)),
      (4, blockHandler(0)),
      (5, event(0)),
      (6, blockHandler(0)),
      (8, blockHandler(0)),
      (10, blockHandler(0)),
    ]

    // Check that we have the exact expected tuples
    t.expect(
      blockNumberLogIndexTuples,
      ~message="Should have correct block number and item coordinates",
    ).toEqual(expectedTuples)
  })

  it("should respect onBlock startBlock configuration", t => {
    // Create onBlock config with startBlock = 5
    let onBlockRegistration = makeOnBlockRegistration(~interval=1, ~startBlock=Some(5))
    let fetchState = makeInitialWithOnBlock(~onBlockRegistrations=Some([onBlockRegistration]))

    // Process a batch that goes from block 0 to 10
    let query: FetchState.query = {
      partitionId: "0",
      itemsTarget: Some(0),
      itemsEst: 0,
      toBlock: None,
      isChunk: false,
      selection: fetchState.normalSelection,
      addresses: TestAddresses.setOf([mockAddress0]),
      fromBlock: 0,
    }
    fetchState->FetchState.startFetchingQueries(~queries=[query])
    let updatedFetchState =
      fetchState->FetchState.handleQueryResult(
        ~query,
        ~latestFetchedBlock=10,
        ~newItems=[mockEvent(~blockNumber=5)],
      )

    // Get all (blockNumber, logIndex) tuples from the queue (including event items)
    let queue = updatedFetchState.buffer
    let blockNumberLogIndexTuples = queue->Array.map(itemCoordinate)

    // Should have block items starting from block 5 (startBlock=5, interval=1) plus event at block 5
    // The event at block 5 is NOT deduplicated with the block item at block 5
    // Expected in reverse order (latest to earliest): block items have higher priority than events at same block
    let expectedTuples = [
      (5, event(0)),
      (5, blockHandler(0)),
      (6, blockHandler(0)),
      (7, blockHandler(0)),
      (8, blockHandler(0)),
      (9, blockHandler(0)),
      (10, blockHandler(0)),
    ]

    // Check that we have the exact expected tuples
    t.expect(
      blockNumberLogIndexTuples,
      ~message="Should have correct block number and item coordinates",
    ).toEqual(expectedTuples)
  })

  it("should respect onBlock endBlock configuration", t => {
    // Create onBlock config with endBlock = 8
    let onBlockRegistration = makeOnBlockRegistration(~interval=1, ~endBlock=Some(8))
    let fetchState = makeInitialWithOnBlock(~onBlockRegistrations=Some([onBlockRegistration]))

    // Process a batch that goes from block 0 to 10
    let query: FetchState.query = {
      partitionId: "0",
      itemsTarget: Some(0),
      itemsEst: 0,
      toBlock: None,
      isChunk: false,
      selection: fetchState.normalSelection,
      addresses: TestAddresses.setOf([mockAddress0]),
      fromBlock: 0,
    }
    fetchState->FetchState.startFetchingQueries(~queries=[query])
    let updatedFetchState =
      fetchState->FetchState.handleQueryResult(
        ~query,
        ~latestFetchedBlock=10,
        ~newItems=[mockEvent(~blockNumber=5)],
      )

    // Get all (blockNumber, logIndex) tuples from the queue (including event items)
    let queue = updatedFetchState.buffer
    let blockNumberLogIndexTuples = queue->Array.map(itemCoordinate)

    // Should have block items that don't exceed endBlock=8 plus event at block 5
    // The event at block 5 is NOT deduplicated with the block item at block 5
    // Expected in reverse order (latest to earliest): block items have higher priority than events at same block
    let expectedTuples = [
      (0, blockHandler(0)),
      (1, blockHandler(0)),
      (2, blockHandler(0)),
      (3, blockHandler(0)),
      (4, blockHandler(0)),
      (5, event(0)),
      (5, blockHandler(0)),
      (6, blockHandler(0)),
      (7, blockHandler(0)),
      (8, blockHandler(0)),
    ]

    // Check that we have the exact expected tuples
    t.expect(
      blockNumberLogIndexTuples,
      ~message="Should have correct block number and item coordinates",
    ).toEqual(expectedTuples)
  })

  it("should handle multiple onBlock configs with different intervals", t => {
    // Create two onBlock configs with different intervals
    let onBlockRegistration1 = makeOnBlockRegistration(~name="config1", ~index=0, ~interval=2)
    let onBlockRegistration2 = makeOnBlockRegistration(~name="config2", ~index=1, ~interval=3)
    let fetchState = makeInitialWithOnBlock(~onBlockRegistrations=Some([onBlockRegistration1, onBlockRegistration2]))

    // Process a batch
    let query: FetchState.query = {
      partitionId: "0",
      itemsTarget: Some(0),
      itemsEst: 0,
      toBlock: None,
      isChunk: false,
      selection: fetchState.normalSelection,
      addresses: TestAddresses.setOf([mockAddress0]),
      fromBlock: 0,
    }
    fetchState->FetchState.startFetchingQueries(~queries=[query])
    let updatedFetchState =
      fetchState->FetchState.handleQueryResult(
        ~query,
        ~latestFetchedBlock=12,
        ~newItems=[mockEvent(~blockNumber=5)],
      )

    // Get all (blockNumber, logIndex) tuples from the queue (including event items)
    let queue = updatedFetchState.buffer
    let blockNumberLogIndexTuples = queue->Array.map(itemCoordinate)

    // Should have block items for both configs plus event at block 5
    // Config1 (interval=2, index=0): blocks 0,2,4,6,8,10,12
    // Config2 (interval=3, index=1): blocks 0,3,6,9,12
    // Combined: 0(c1),0(c2),2(c1),3(c2),4(c1),5(event),6(c1),6(c2),8(c1),9(c2),10(c1),12(c1),12(c2)
    // Expected in reverse order (latest to earliest): [12(c2),12(c1),10(c1),9(c2),8(c1),6(c2),6(c1),5(event),4(c1),3(c2),2(c1),0(c2),0(c1)]
    let expectedTuples = [
      (0, blockHandler(0)),
      (0, blockHandler(1)),
      (2, blockHandler(0)),
      (3, blockHandler(1)),
      (4, blockHandler(0)),
      (5, event(0)),
      (6, blockHandler(0)),
      (6, blockHandler(1)),
      (8, blockHandler(0)),
      (9, blockHandler(1)),
      (10, blockHandler(0)),
      (12, blockHandler(0)),
      (12, blockHandler(1)),
    ]

    // Check that we have the exact expected tuples
    t.expect(
      blockNumberLogIndexTuples,
      ~message="Should have correct block number and item coordinates",
    ).toEqual(expectedTuples)
  })

  it("should not add block items when onBlock configs are not provided", t => {
    // Create fetch state without onBlock configs
    let fetchState = makeInitialWithOnBlock(~onBlockRegistrations=None)

    // Process a batch
    let query: FetchState.query = {
      partitionId: "0",
      itemsTarget: Some(0),
      itemsEst: 0,
      toBlock: None,
      isChunk: false,
      selection: fetchState.normalSelection,
      addresses: TestAddresses.setOf([mockAddress0]),
      fromBlock: 0,
    }
    fetchState->FetchState.startFetchingQueries(~queries=[query])
    let updatedFetchState =
      fetchState->FetchState.handleQueryResult(
        ~query,
        ~latestFetchedBlock=10,
        ~newItems=[mockEvent(~blockNumber=5)],
      )

    // Verify that no block items were added when onBlock configs are not provided
    let queue = updatedFetchState.buffer
    let blockNumberLogIndexTuples = queue->Array.map(itemCoordinate)

    // Should have only the event item
    let expectedTuples = [(5, event(0))]

    // Check that we have the exact expected tuples
    t.expect(
      blockNumberLogIndexTuples,
      ~message="Should have correct block number and item coordinates",
    ).toEqual(expectedTuples)
  })
})
