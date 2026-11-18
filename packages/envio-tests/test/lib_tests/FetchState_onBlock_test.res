open Vitest

let chainId = 0->ChainId.fromInt

// Spread into query literals so the common fields don't have to be repeated;
// every other field is overridden at the call site.

let mockAddress0 = Envio.TestHelpers.Addresses.mockAddresses[0]->Option.getOrThrow

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
  blockFieldMask: None,
}

let makeInitialWithOnBlock = (~startBlock=0, ~maxOnBlockBufferSize=5000, ~onBlockRegistrations) => {
  let onEventRegistrations = [baseEventConfig]
  let addresses = [
    {
      Internal.address: mockAddress0,
      contractName: "Gravatar",
      registrationBlock: -1,
    },
  ]
  let addressStore = TestAddresses.makeStore(~onEventRegistrations)
  TestFetchState.make(
    ~onNotice=ignore,
    ~onEventRegistrations,
    ~addressStore,
    ~addressRows=TestAddresses.addressRows(~addresses, ~onEventRegistrations),
    ~startBlock,
    ~endBlock=None,
    ~maxAddrInPartition=3,
    ~maxOnBlockBufferSize,
    ~chainId,
    ~onBlockRegistrations?,
    // A height the responses below stay under: onBlock items are only generated
    // up to the head, and no query is issued before one is known.
    ~knownHeight=100,
  )
}

let mockEvent = (~blockNumber, ~logIndex=0): Internal.item => Internal.Event({
  chainId,
  blockNumber,
  // Carries an `index` so the buffer's dedup key (blockNumber, logIndex, index)
  // resolves; the rest of the registration is unused by these tests.
  onEventRegistration: Utils.magic({"index": 0}),
  logIndex,
  transactionIndex: 0,
  payload: "Mock event in fetchstate test"->(Utils.magic: string => Internal.eventPayload),
})

describe("FetchState onBlock functionality", () => {
  // A response is applied before the height it reported, so it can run past the
  // height the chain still knows. onBlock items are generated up to the last
  // event a full buffer holds, which must not take them past that height.
  it("should generate block items no further than the known height when the buffer is full", t => {
    let fetchState = makeInitialWithOnBlock(
      ~maxOnBlockBufferSize=200,
      ~onBlockRegistrations=Some([makeOnBlockRegistration(~interval=1, ~startBlock=Some(0))]),
    )
    let query: FetchState.query = {
      partitionId: "0",
      itemsEst: 0,
      toBlock: None,
      isChunk: false,
      selection: fetchState.normalSelection,
      addresses: TestAddresses.setOf([mockAddress0]),
      fromBlock: 0,
    }
    fetchState->FetchState.startFetchingQueries(~queries=[query])
    let updatedFetchState =
      fetchState->TestFetchState.handleQueryResult(
        ~query,
        ~latestFetchedBlock=300,
        ~page=TestEventStore.pageOf(
          Array.fromInitializer(~length=200, i => mockEvent(~blockNumber=101 + i)),
        ),
      )

    // The events start at block 101, so every row at or below 100 is a block
    // handler's.
    let lastBlockItem =
      updatedFetchState
      ->TestFetchState.bufferedBlockNumbers
      ->Array.filter(block => block <= 100)
      ->Array.last
    t.expect((updatedFetchState.latestOnBlockBlockNumber, lastBlockItem)).toEqual((100, Some(100)))
  })
})
