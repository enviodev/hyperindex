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

describe("RpcSyncWorker - getEventTransactionOrThrow", () => {
  let neverGetTransactionFields = _ => Assert.fail("The getTransactionFields should not be called")

  it("Panics with invalid schema", () => {
    Assert.throws(
      () => {
        RpcWorker.makeThrowingGetEventTransaction(~getTransactionFields=neverGetTransactionFields)(
          mockEthersLog(),
          ~transactionSchema=S.string,
        )
      },
      ~error={
        "message": "Unexpected internal error: transactionSchema is not an object",
      },
    )
  })

  Async.it("Works with a single transactionIndex field", async () => {
    let getEventTransactionOrThrow = RpcWorker.makeThrowingGetEventTransaction(
      ~getTransactionFields=neverGetTransactionFields,
    )
    Assert.deepEqual(
      await mockEthersLog()->getEventTransactionOrThrow(
        ~transactionSchema=S.schema(
          s =>
            {
              "transactionIndex": s.matches(S.int),
            },
        ),
      ),
      {
        "transactionIndex": 1,
      },
    )
  })

  Async.it("Works with a single hash field", async () => {
    let getEventTransactionOrThrow = RpcWorker.makeThrowingGetEventTransaction(
      ~getTransactionFields=neverGetTransactionFields,
    )
    Assert.deepEqual(
      await mockEthersLog()->getEventTransactionOrThrow(
        ~transactionSchema=S.schema(
          s =>
            {
              "hash": s.matches(S.string),
            },
        ),
      ),
      {
        "hash": "0xabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdef",
      },
    )
  })

  Async.it("Works with a only transactionIndex & hash field", async () => {
    let getEventTransactionOrThrow = RpcWorker.makeThrowingGetEventTransaction(
      ~getTransactionFields=neverGetTransactionFields,
    )
    Assert.deepEqual(
      await mockEthersLog()->getEventTransactionOrThrow(
        ~transactionSchema=S.schema(
          s =>
            {
              "hash": s.matches(S.string),
              "transactionIndex": s.matches(S.int),
            },
        ),
      ),
      {
        "hash": "0xabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdef",
        "transactionIndex": 1,
      },
    )

    // In different fields order in the schema
    let getEventTransactionOrThrow = RpcWorker.makeThrowingGetEventTransaction(
      ~getTransactionFields=neverGetTransactionFields,
    )
    Assert.deepEqual(
      await mockEthersLog()->getEventTransactionOrThrow(
        ~transactionSchema=S.schema(
          s =>
            {
              "transactionIndex": s.matches(S.int),
              "hash": s.matches(S.string),
            },
        ),
      ),
      {
        "hash": "0xabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdef",
        "transactionIndex": 1,
      },
    )
  })

  Async.it("Queries transaction with a non-log field (with real Ethers.provider)", async () => {
    let testTransactionHash = "0x3dce529e9661cfb65defa88ae5cd46866ddf39c9751d89774d89728703c2049f"

    let provider = Ethers.JsonRpcProvider.make(
      ~rpcUrls=["https://eth.llamarpc.com"],
      ~chainId=1,
      ~fallbackStallTimeout=0,
    )
    let getTransactionFields = Ethers.JsonRpcProvider.makeGetTransactionFields(
      ~getTransactionByHash=transactionHash =>
        provider->Ethers.JsonRpcProvider.getTransaction(~transactionHash),
    )

    let getEventTransactionOrThrow = RpcWorker.makeThrowingGetEventTransaction(
      ~getTransactionFields,
    )
    Assert.deepEqual(
      await mockEthersLog(~transactionHash=testTransactionHash)->getEventTransactionOrThrow(
        ~transactionSchema=S.schema(
          s =>
            {
              "hash": s.matches(S.string),
              "transactionIndex": s.matches(S.int),
              "from": s.matches(S.option(Address.schema)),
              "to": s.matches(S.option(Address.schema)),
              // "gas": s.matches(BigInt.nativeSchema), --- Not exposed by Ethers
              "gasPrice": s.matches(S.option(BigInt.nativeSchema)),
              "maxPriorityFeePerGas": s.matches(S.option(BigInt.nativeSchema)),
              "maxFeePerGas": s.matches(S.option(BigInt.nativeSchema)),
              // "cumulativeGasUsed": s.matches(BigInt.nativeSchema), --- Invalid transaction field "cumulativeGasUsed" found in the RPC response. Error: Expected bigint
              // "effectiveGasPrice": s.matches(BigInt.nativeSchema), --- Invalid transaction field "effectiveGasPrice" found in the RPC response. Error: Expected bigint
              // "gasUsed": s.matches(BigInt.nativeSchema), --- Invalid transaction field "gasUsed" found in the RPC response. Error: Expected bigint
              "input": s.matches(S.string),
              // "nonce": s.matches(BigInt.nativeSchema), --- Returned as number by ethers
              "value": s.matches(BigInt.nativeSchema),
              // "v": s.matches(S.option(S.string)), --- Invalid transaction field "v" found in the RPC response. Error: Expected Option(String), received 28
              // "r": s.matches(S.option(S.string)), --- Inside of signature
              // "s": s.matches(S.option(S.string)),
              // "yParity": s.matches(S.option(S.string)), --- Inside of signature and decoded to int
              "contractAddress": s.matches(S.option(Address.schema)),
              // "logsBloom": s.matches(S.string), --- Invalid transaction field "logsBloom" found in the RPC response. Error: Expected String, received undefined
              "root": s.matches(S.option(S.string)),
              "status": s.matches(S.option(S.int)),
              // "chainId": s.matches(S.option(S.int)), --- Decoded to bigint by ethers
              "maxFeePerBlobGas": s.matches(S.option(BigInt.nativeSchema)),
              "blobVersionedHashes": s.matches(S.option(S.array(S.string))),
              "kind": s.matches(S.option(S.int)),
              "l1Fee": s.matches(S.option(BigInt.nativeSchema)),
              "l1GasPrice": s.matches(S.option(BigInt.nativeSchema)),
              "l1GasUsed": s.matches(S.option(BigInt.nativeSchema)),
              "l1FeeScalar": s.matches(S.option(S.float)),
              "gasUsedForL1": s.matches(S.option(BigInt.nativeSchema)),
            },
        ),
      ),
      {
        "hash": testTransactionHash,
        "transactionIndex": 1,
        "from": Some("0x95222290DD7278Aa3Ddd389Cc1E1d165CC4BAfe5"->Address.Evm.fromStringOrThrow),
        "to": Some("0x4675C7e5BaAFBFFbca748158bEcBA61ef3b0a263"->Address.Evm.fromStringOrThrow),
        "gasPrice": Some(17699339493n),
        "maxPriorityFeePerGas": Some(0n),
        "maxFeePerGas": Some(17699339493n),
        "input": "0x",
        "value": 34302998902926621n,
        // "r": Some("0xb73e53731ff8484f3c30c2850328f0ad7ca5a8dd8681d201ba52777aaf972f87"),
        // "s": Some("0x10c1bcf56abfb5dc6dae06e1c0e441b68068fc23064364eaf0ae3e76e07b553a"),
        "contractAddress": None,
        "root": None,
        "status": None,
        // "yParity": Some("0x1"),
        // "chainId": Some(1),
        "maxFeePerBlobGas": None,
        "blobVersionedHashes": None,
        "kind": None,
        "l1Fee": None,
        "l1GasPrice": None,
        "l1GasUsed": None,
        "l1FeeScalar": None,
        "gasUsedForL1": None,
      }->Obj.magic,
    )
  })

  Async.it("Error with a value not matching the schema", async () => {
    let getEventTransactionOrThrow = RpcWorker.makeThrowingGetEventTransaction(
      ~getTransactionFields=neverGetTransactionFields,
    )
    Assert.throws(
      () => {
        mockEthersLog()->getEventTransactionOrThrow(
          ~transactionSchema=S.schema(
            s =>
              {
                "hash": s.matches(S.int),
              },
          ),
        )
      },
      ~error={
        "message": `Invalid transaction field "hash" found in the RPC response. Error: Expected Int, received "0xabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdef"`,
      },
    )
  })
})
