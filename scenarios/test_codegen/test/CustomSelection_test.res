open Vitest

// Compile-time type assertions for custom field selection
// Verify that selected fields have the expected types
let _ = (event: Indexer.Gravatar.CustomSelection.event) => {
  let _to: option<Address.t> = event.transaction.to
  let _from: option<Address.t> = event.transaction.from
  let _hash: string = event.transaction.hash
  let _number: int = event.block.number
  let _timestamp: int = event.block.timestamp
  let _blockHash: string = event.block.hash
  let _parentHash: string = event.block.parentHash
}

// Events without custom field selection should use the global one
let _ = (event: Indexer.Gravatar.EmptyEvent.event) => {
  let _transactionIndex: int = event.transaction.transactionIndex
  let _hash: string = event.transaction.hash
  let _number: int = event.block.number
  let _timestamp: int = event.block.timestamp
  let _blockHash: string = event.block.hash
}

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
