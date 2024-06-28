open Belt
open Ava

// NOTE: this is likely a temporary feature - can delete if feature no longer important.

let determineNextEvent_unordered = ChainManager.ExposedForTesting_Hidden.createDetermineNextEventFunction(
  ~isUnorderedMultichainMode=true,
)
let determineNextEvent_ordered = ChainManager.ExposedForTesting_Hidden.createDetermineNextEventFunction(
  ~isUnorderedMultichainMode=false,
)

let makeNoItem = timestamp => FetchState.NoItem({blockTimestamp: timestamp, blockNumber: 0})
let makeMockQItem = (timestamp, chain): Types.eventBatchQueueItem => {
  {
    timestamp,
    chain,
    blockNumber: 987654,
    logIndex: 123456,
    event: "SINGLE TEST EVENT"->Obj.magic,
  }
}
let makeMockFetchState = (~latestFetchedBlockTimestamp, ~item): FetchState.t => {
  registerType: RootRegister({endBlock: None}),
  latestFetchedBlock: {
    blockTimestamp: latestFetchedBlockTimestamp,
    blockNumber: 0,
  },
  contractAddressMapping: ContractAddressingMap.make(),
  fetchedEventQueue: item->Option.mapWithDefault(list{}, v => list{v}),
  dynamicContracts: FetchState.DynamicContractsMap.empty,
}

test("should always take an event if there is one, even if other chains haven't caught up", (.
  t,
) => {
  let singleItem = makeMockQItem(654, Chain_137)
  let earliestItem = makeNoItem(5) /* earlier timestamp than the test event */

  let fetchStatesMap = ChainMap.make(chain =>
    switch chain {
    | Chain_1 =>
      makeMockFetchState(
        ~latestFetchedBlockTimestamp=5,
        ~item=None,
      ) /* earlier timestamp than the test event */
    | Chain_137 => makeMockFetchState(~latestFetchedBlockTimestamp=5, ~item=Some(singleItem))
    | Chain_1337 => makeMockFetchState(~latestFetchedBlockTimestamp=655, ~item=None)
    }
  )

  let {earliestEventResponse: {earliestQueueItem}} =
    determineNextEvent_unordered(fetchStatesMap)->Result.getExn

  t->Assert.deepEqual(.
    earliestQueueItem,
    Item(singleItem),
    ~message="Should have taken the single item",
  )

  let {earliestEventResponse: {earliestQueueItem}} =
    determineNextEvent_ordered(fetchStatesMap)->Result.getExn

  t->Assert.deepEqual(.
    earliestQueueItem,
    earliestItem,
    ~message="Should return the `NoItem` that is earliest since it is earlier than the `Item`",
  )
})
test(
  "should always take the lower of two events if there are any, even if other chains haven't caught up",
  (. t) => {
    let earliestItemTimestamp = 653
    let singleItemTimestamp = 654
    let singleItem = makeMockQItem(singleItemTimestamp, Chain_137)

    let fetchStatesMap = ChainMap.make(chain =>
      switch chain {
      | Chain_1 =>
        makeMockFetchState(
          ~latestFetchedBlockTimestamp=earliestItemTimestamp,
          ~item=None,
        ) /* earlier timestamp than the test event */
      | Chain_137 =>
        makeMockFetchState(~latestFetchedBlockTimestamp=singleItemTimestamp, ~item=Some(singleItem))
      | Chain_1337 =>
        let higherTS = singleItemTimestamp + 1
        makeMockFetchState(
          ~latestFetchedBlockTimestamp=higherTS,
          ~item=Some(makeMockQItem(higherTS, chain)),
        )
      }
    )

    // let example: array<ChainFetcher.eventQueuePeek> = [
    //   earliestItem,
    //   NoItem(653 /* earlier timestamp than the test event */, Chain_1),
    //   Item({...singleItem, timestamp: singleItem.timestamp + 1}),
    //   Item(singleItem),
    //   NoItem(655 /* later timestamp than the test event */, Chain_1),
    // ]

    let {earliestEventResponse: {earliestQueueItem}} =
      determineNextEvent_unordered(fetchStatesMap)->Result.getExn

    t->Assert.deepEqual(.
      earliestQueueItem,
      Item(singleItem),
      ~message="Should have taken the single item",
    )

    let {earliestEventResponse: {earliestQueueItem}} =
      determineNextEvent_ordered(fetchStatesMap)->Result.getExn

    t->Assert.deepEqual(.
      earliestQueueItem,
      makeNoItem(earliestItemTimestamp),
      ~message="Should return the `NoItem` that is earliest since it is earlier than the `Item`",
    )
  },
)
