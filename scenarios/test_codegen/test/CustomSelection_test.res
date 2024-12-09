open RescriptMocha

open TestHelpers

type expectedTransactionFields = {
  to: option<Address.t>,
  from: option<Address.t>,
  hash: string,
}

type expectedBlockFields = {
  number: int,
  timestamp: int,
  hash: string,
  parentHash: string,
}

type expectedGlobalTransactionFields = {
  transactionIndex: int,
  hash: string,
}

type expectedGlobalBlockFields = {
  number: int,
  timestamp: int,
  hash: string,
}

// The same as for TS but in ReScript
Async.it("Handles event with a custom field selection (in ReScript)", async () => {
  // Initializing the mock database
  let mockDbInitial = MockDb.createMockDb()

  // Every time use different hash to make sure the test data isn't stale
  let hash = "0x" ++ Js.Math.random_int(0, 10000000)->Js.Int.toString

  let event = Gravatar.CustomSelection.createMockEvent({
    mockEventData: {
      transaction: {
        // Can pass transactionIndex event though it's not selected for the event
        transactionIndex: 12,
        hash,
        to: None,
        from: Some("0xfoo"->Address.unsafeFromString),
      },
      block: {
        parentHash: "0xParentHash",
      },
    },
  })

  // Test content of the generated record type
  let _ = ((event.transaction: Types.Gravatar.CustomSelection.transaction :> expectedTransactionFields) :> Types.Gravatar.CustomSelection.transaction)
  let _ = ((event.block: Types.Gravatar.CustomSelection.block :> expectedBlockFields) :> Types.Gravatar.CustomSelection.block)

  // The event not used for the test, but we want to make sure
  // that events without custom field selection use the global one
  let anotherEvent = Gravatar.EmptyEvent.createMockEvent({})
  let _ = ((anotherEvent.transaction: Types.Gravatar.EmptyEvent.transaction :> expectedGlobalTransactionFields) :> Types.Gravatar.EmptyEvent.transaction)
  let _ = ((anotherEvent.block: Types.Gravatar.EmptyEvent.block :> expectedGlobalBlockFields) :> Types.Gravatar.EmptyEvent.block)

  let updatedMockDb = await Gravatar.CustomSelection.processEvent({
    event,
    mockDb: mockDbInitial,
  })

  Assert.notEqual(updatedMockDb.entities.customSelectionTestPass.get(hash), None)
})
