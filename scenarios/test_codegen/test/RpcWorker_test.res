open RescriptMocha

let mockEthersLog = (): Ethers.log => {
  blockNumber: 123456,
  blockHash: "0xabcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
  removed: Some(false),
  address: Address.Evm.fromStringOrThrow("0x1234567890abcdef1234567890abcdef12345678"),
  data: "0xdeadbeefdeadbeefdeadbeefdeadbeef",
  topics: [
    EvmTypes.Hex.fromStringUnsafe(
      "0xd78ad95fa46c994b6551d0da85fc275fe613dbe680204dd5837f03aa2f863b9b",
    ),
    EvmTypes.Hex.fromStringUnsafe(
      "0x0000000000000000000000000000000000000000000000000000000000000000",
    ),
  ],
  transactionHash: "0xabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdef",
  transactionIndex: 1,
  logIndex: 2,
}

describe_only("RpcSyncWorker - getEventTransactionOrThrow", () => {
  let neverGetTransaction = _ => Assert.fail("The getTransaction should not be called")

  it("Panics with invalid schema", () => {
    Assert.throws(
      () => {
        RpcWorker.makeThrowingGetEventTransaction(
          ~transactionSchema=S.string,
          ~getTransaction=neverGetTransaction,
        )
      },
      ~error={
        "message": "Unexpected internal error: transactionSchema is not an object",
      },
    )
  })

  Async.it("Works with a single transactionIndex field", async () => {
    let getEventTransactionOrThrow = RpcWorker.makeThrowingGetEventTransaction(
      ~transactionSchema=S.schema(
        s =>
          {
            "transactionIndex": s.matches(S.int),
          },
      ),
      ~getTransaction=neverGetTransaction,
    )
    Assert.deepEqual(
      await mockEthersLog()->getEventTransactionOrThrow,
      {
        "transactionIndex": 1,
      },
    )
  })

  Async.it("Works with a single hash field", async () => {
    let getEventTransactionOrThrow = RpcWorker.makeThrowingGetEventTransaction(
      ~transactionSchema=S.schema(
        s =>
          {
            "hash": s.matches(S.string),
          },
      ),
      ~getTransaction=neverGetTransaction,
    )
    Assert.deepEqual(
      await mockEthersLog()->getEventTransactionOrThrow,
      {
        "hash": "0xabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdef",
      },
    )
  })

  Async.it("Works with a only transactionIndex & hash field", async () => {
    let getEventTransactionOrThrow = RpcWorker.makeThrowingGetEventTransaction(
      ~transactionSchema=S.schema(
        s =>
          {
            "hash": s.matches(S.string),
            "transactionIndex": s.matches(S.int),
          },
      ),
      ~getTransaction=neverGetTransaction,
    )
    Assert.deepEqual(
      await mockEthersLog()->getEventTransactionOrThrow,
      {
        "hash": "0xabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdef",
        "transactionIndex": 1,
      },
    )

    // In different fields order in the schema
    let getEventTransactionOrThrow = RpcWorker.makeThrowingGetEventTransaction(
      ~transactionSchema=S.schema(
        s =>
          {
            "transactionIndex": s.matches(S.int),
            "hash": s.matches(S.string),
          },
      ),
      ~getTransaction=neverGetTransaction,
    )
    Assert.deepEqual(
      await mockEthersLog()->getEventTransactionOrThrow,
      {
        "hash": "0xabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdef",
        "transactionIndex": 1,
      },
    )
  })

  Async.it("Error with a value not matching the schema", async () => {
    let getEventTransactionOrThrow = RpcWorker.makeThrowingGetEventTransaction(
      ~transactionSchema=S.schema(
        s =>
          {
            "hash": s.matches(S.int),
          },
      ),
      ~getTransaction=neverGetTransaction,
    )
    Assert.throws(
      () => {
        mockEthersLog()->getEventTransactionOrThrow
      },
      ~error={
        "message": `Invalid transaction field "hash" found in the RPC response. Error: Expected Int, received "0xabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdef"`,
      },
    )
  })
})
