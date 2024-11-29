open RescriptMocha

let mockEthersLog = (
  ~transactionHash="0xabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdef",
): Ethers.log => {
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
  transactionHash,
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

  Async.it_only(
    "Queries transaction with a non-log field (with real Ethers.provider)",
    async () => {
      let testTransactionHash = "0x3dce529e9661cfb65defa88ae5cd46866ddf39c9751d89774d89728703c2049f"

      let provider = Ethers.JsonRpcProvider.make(
        ~rpcUrls=["https://eth.llamarpc.com"],
        ~chainId=1,
        ~fallbackStallTimeout=0,
      )
      let getEventTransactionOrThrow = RpcWorker.makeThrowingGetEventTransaction(
        ~transactionSchema=S.schema(
          s =>
            {
              "hash": s.matches(S.string),
              "transactionIndex": s.matches(S.int),
              "from": s.matches(S.null(Address.schema)),
              "to": s.matches(S.null(Address.schema)),
              // "gas": s.matches(BigInt.schema),
              "gasPrice": s.matches(S.null(BigInt.schema)),
              "maxPriorityFeePerGas": s.matches(S.null(BigInt.schema)),
              "maxFeePerGas": s.matches(S.null(BigInt.schema)),
              "cumulativeGasUsed": s.matches(BigInt.schema),
              "effectiveGasPrice": s.matches(BigInt.schema),
              "gasUsed": s.matches(BigInt.schema),
              "input": s.matches(S.string),
              "nonce": s.matches(BigInt.schema),
              "value": s.matches(BigInt.schema),
              "v": s.matches(S.null(S.string)),
              "r": s.matches(S.null(S.string)),
              "s": s.matches(S.null(S.string)),
              "contractAddress": s.matches(S.null(Address.schema)),
              "logsBloom": s.matches(S.string),
              "root": s.matches(S.null(S.string)),
              "status": s.matches(S.null(S.int)),
              "yParity": s.matches(S.null(S.string)),
              "chainId": s.matches(S.null(S.int)),
              "maxFeePerBlobGas": s.matches(S.null(BigInt.schema)),
              "blobVersionedHashes": s.matches(S.null(S.array(S.string))),
              "kind": s.matches(S.null(S.int)),
              "l1Fee": s.matches(S.null(BigInt.schema)),
              "l1GasPrice": s.matches(S.null(BigInt.schema)),
              "l1GasUsed": s.matches(S.null(BigInt.schema)),
              "l1FeeScalar": s.matches(S.null(S.float)),
              "gasUsedForL1": s.matches(S.null(BigInt.schema)),
            },
        ),
        ~getTransaction=log => {
          let transactionHash = log.transactionHash
          Assert.deepEqual(transactionHash, testTransactionHash)
          provider->Ethers.JsonRpcProvider.getTransaction(~transactionHash)
        },
      )
      Assert.deepEqual(
        await mockEthersLog(~transactionHash=testTransactionHash)->getEventTransactionOrThrow,
        {
          "hash": testTransactionHash,
          "transactionIndex": 1,
          "from": Some(""->Address.Evm.fromStringOrThrow),
          "to": Some("0x4675C7e5BaAFBFFbca748158bEcBA61ef3b0a263"->Address.Evm.fromStringOrThrow),
          // "gas": 0n,
          "gasPrice": None,
          "maxPriorityFeePerGas": None,
          "maxFeePerGas": None,
          "cumulativeGasUsed": 0n,
          "effectiveGasPrice": 0n,
          "gasUsed": 0n,
          "input": "",
          "nonce": 0n,
          "value": 0n,
          "v": None,
          "r": None,
          "s": None,
          "contractAddress": None,
          "logsBloom": "",
          "root": None,
          "status": None,
          "yParity": None,
          "chainId": None,
          "maxFeePerBlobGas": None,
          "blobVersionedHashes": None,
          "kind": None,
          "l1Fee": None,
          "l1GasPrice": None,
          "l1GasUsed": None,
          "l1FeeScalar": None,
          "gasUsedForL1": None,
        },
      )
    },
  )

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
