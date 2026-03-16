open Vitest

open TestHelpers

// The same as for TS but in ReScript
Async.it("Handles event with a custom field selection (in ReScript)", async t => {
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
        from: "0xfoo"->Address.unsafeFromString,
      },
      block: {
        parentHash: "0xParentHash",
      },
    },
  })

  // All events now use the same Envio.evmBlock and Envio.evmTransaction types.
  // Runtime proxy validates field access based on field_selection in config.yaml.
  let _ = (event.transaction: Envio.evmTransaction)
  let _ = (event.block: Envio.evmBlock)

  let updatedMockDb = await Gravatar.CustomSelection.processEvent({
    event,
    mockDb: mockDbInitial,
  })

  t.expect(updatedMockDb.entities.customSelectionTestPass.get(hash)).not.toBe(None)
})
