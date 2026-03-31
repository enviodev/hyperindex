open Vitest

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

// Compile-time type assertions for custom field selection
// These verify that generated record types match expected field sets
let _ = (
  (Obj.magic(): Indexer.Gravatar.CustomSelection.transaction :> expectedTransactionFields) :> Indexer.Gravatar.CustomSelection.transaction
)
let _ = (
  (Obj.magic(): Indexer.Gravatar.CustomSelection.block :> expectedBlockFields) :> Indexer.Gravatar.CustomSelection.block
)

// Events without custom field selection should use the global one
let _ = (
  (Obj.magic(): Indexer.Gravatar.EmptyEvent.transaction :> expectedGlobalTransactionFields) :> Indexer.Gravatar.EmptyEvent.transaction
)
let _ = (
  (Obj.magic(): Indexer.Gravatar.EmptyEvent.block :> expectedGlobalBlockFields) :> Indexer.Gravatar.EmptyEvent.block
)

Async.it("Handles event with a custom field selection (in ReScript)", async t => {
  let indexer = Indexer.createTestIndexer()

  let processConfig: Indexer.testIndexerProcessConfig = {
    "chains": {
      "1337": {
        "startBlock": 1,
        "endBlock": 100,
        "simulate": [
          {
            "contract": "Gravatar",
            "event": "CustomSelection",
            "transaction": {"from": "0xfoo"},
            "block": {"parentHash": "0xParentHash"},
          },
        ],
      },
    },
  }->Utils.magic
  let result = await indexer.process(processConfig)
  t.expect(result.changes->Array.length).toEqual(1)
})
