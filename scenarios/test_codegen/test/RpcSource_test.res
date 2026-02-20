open RescriptMocha

let testApiToken = "3dc856dd-b0ea-494f-b27e-017b8b6b7e07"

let mockLog = (
  ~transactionHash="0xabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdef",
): Rpc.GetLogs.log => {
  blockNumber: 123456,
  blockHash: "0xabcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
  removed: false,
  address: Address.Evm.fromStringOrThrow("0x1234567890abcdef1234567890abcdef12345678"),
  data: "0xdeadbeefdeadbeefdeadbeefdeadbeef",
  topics: [
    "0xd78ad95fa46c994b6551d0da85fc275fe613dbe680204dd5837f03aa2f863b9b",
    "0x0000000000000000000000000000000000000000000000000000000000000000",
  ],
  transactionHash,
  transactionIndex: 1,
  logIndex: 2,
}

describe("RpcSource - name", () => {
  it("Returns the name of the source including sanitized rpc url", () => {
    let source = RpcSource.make({
      url: "https://eth.rpc.hypersync.xyz?api_key=123",
      chain: MockConfig.chain1337,
      eventRouter: EventRouter.empty(),
      sourceFor: Sync,
      syncConfig: EvmChain.getSyncConfig({}),
      allEventSignatures: [],
      lowercaseAddresses: false,
    })
    Assert.equal(source.name, "RPC (eth.rpc.hypersync.xyz)")
  })
})

describe("RpcSource - getHeightOrThrow", () => {
  Async.it("Returns the name of the source including sanitized rpc url", async () => {
    let source = RpcSource.make({
      url: `https://eth.rpc.hypersync.xyz/${testApiToken}`,
      chain: MockConfig.chain1337,
      eventRouter: EventRouter.empty(),
      sourceFor: Sync,
      syncConfig: EvmChain.getSyncConfig({}),
      allEventSignatures: ["a", "b", "c"],
      lowercaseAddresses: false,
    })
    let height = await source.getHeightOrThrow()
    Assert.equal(height > 21994218, true)
    Assert.equal(height < 30000000, true)
  })
})

describe("RpcSource - getEventTransactionOrThrow", () => {
  let neverGetTransactionJson = _ => Assert.fail("getTransactionJson should not be called")
  let neverGetReceiptJson = _ => Assert.fail("getReceiptJson should not be called")

  it("Panics with invalid schema", () => {
    Assert.throws(
      () => {
        RpcSource.makeThrowingGetEventTransaction(
          ~getTransactionJson=neverGetTransactionJson,
          ~getReceiptJson=neverGetReceiptJson,
          ~lowercaseAddresses=false,
        )(mockLog(), ~transactionSchema=S.string)
      },
      ~error={
        "message": "Unexpected internal error: transactionSchema is not an object",
      },
    )
  })

  Async.it(
    "Returns empty object when empty field selection. Doesn't make a transaction request",
    async () => {
      let getEventTransactionOrThrow = RpcSource.makeThrowingGetEventTransaction(
        ~getTransactionJson=neverGetTransactionJson,
        ~getReceiptJson=neverGetReceiptJson,
        ~lowercaseAddresses=false,
      )
      Assert.deepEqual(
        await mockLog()->getEventTransactionOrThrow(~transactionSchema=S.object(_ => ())),
        %raw(`{}`),
      )
    },
  )

  Async.it("Works with a single transactionIndex field", async () => {
    let getEventTransactionOrThrow = RpcSource.makeThrowingGetEventTransaction(
      ~getTransactionJson=neverGetTransactionJson,
      ~getReceiptJson=neverGetReceiptJson,
      ~lowercaseAddresses=false,
    )
    Assert.deepEqual(
      await mockLog()->getEventTransactionOrThrow(
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
    let getEventTransactionOrThrow = RpcSource.makeThrowingGetEventTransaction(
      ~getTransactionJson=neverGetTransactionJson,
      ~getReceiptJson=neverGetReceiptJson,
      ~lowercaseAddresses=false,
    )
    Assert.deepEqual(
      await mockLog()->getEventTransactionOrThrow(
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
    let getEventTransactionOrThrow = RpcSource.makeThrowingGetEventTransaction(
      ~getTransactionJson=neverGetTransactionJson,
      ~getReceiptJson=neverGetReceiptJson,
      ~lowercaseAddresses=false,
    )
    Assert.deepEqual(
      await mockLog()->getEventTransactionOrThrow(
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
    let getEventTransactionOrThrow = RpcSource.makeThrowingGetEventTransaction(
      ~getTransactionJson=neverGetTransactionJson,
      ~getReceiptJson=neverGetReceiptJson,
      ~lowercaseAddresses=false,
    )
    Assert.deepEqual(
      await mockLog()->getEventTransactionOrThrow(
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

  Async.it("Queries transaction fields from raw JSON (with real RPC)", async () => {
    let testTransactionHash = "0x3dce529e9661cfb65defa88ae5cd46866ddf39c9751d89774d89728703c2049f"

    let rpcUrl = `https://eth.rpc.hypersync.xyz/${testApiToken}`
    let client = Rest.client(rpcUrl)

    let getEventTransactionOrThrow = RpcSource.makeThrowingGetEventTransaction(
      ~getTransactionJson=async txHash =>
        switch await Rpc.GetTransactionByHash.rawRoute->Rest.fetch(txHash, ~client) {
        | Some(json) => json
        | None => Js.Exn.raiseError(`Transaction not found for hash: ${txHash}`)
        },
      ~getReceiptJson=async txHash =>
        switch await Rpc.GetTransactionReceipt.rawRoute->Rest.fetch(txHash, ~client) {
        | Some(json) => json
        | None => Js.Exn.raiseError(`Receipt not found for hash: ${txHash}`)
        },
      ~lowercaseAddresses=false,
    )
    Assert.deepEqual(
      await mockLog(~transactionHash=testTransactionHash)->getEventTransactionOrThrow(
        ~transactionSchema=S.schema(
          s =>
            {
              "hash": s.matches(S.string),
              "transactionIndex": s.matches(S.int),
              "from": s.matches(Address.schema),
              "to": s.matches(Address.schema),
              "gas": s.matches(BigInt.nativeSchema),
              "gasPrice": s.matches(BigInt.nativeSchema),
              "maxPriorityFeePerGas": s.matches(BigInt.nativeSchema),
              "maxFeePerGas": s.matches(BigInt.nativeSchema),
              "input": s.matches(S.string),
              "nonce": s.matches(BigInt.nativeSchema),
              "value": s.matches(BigInt.nativeSchema),
              "v": s.matches(S.string),
              "r": s.matches(S.string),
              "s": s.matches(S.string),
              "yParity": s.matches(S.string),
              // Receipt fields
              "gasUsed": s.matches(BigInt.nativeSchema),
              "effectiveGasPrice": s.matches(BigInt.nativeSchema),
              "status": s.matches(S.int),
            },
        ),
      ),
      {
        "hash": testTransactionHash,
        "transactionIndex": 1,
        "from": "0x95222290DD7278Aa3Ddd389Cc1E1d165CC4BAfe5"->Address.Evm.fromStringOrThrow,
        "to": "0x4675C7e5BaAFBFFbca748158bEcBA61ef3b0a263"->Address.Evm.fromStringOrThrow,
        "gasPrice": 17699339493n,
        "gas": 21000n,
        "maxPriorityFeePerGas": 0n,
        "maxFeePerGas": 17699339493n,
        "input": "0x",
        "nonce": 1722147n,
        "value": 34302998902926621n,
        "r": "0xb73e53731ff8484f3c30c2850328f0ad7ca5a8dd8681d201ba52777aaf972f87",
        "s": "0x10c1bcf56abfb5dc6dae06e1c0e441b68068fc23064364eaf0ae3e76e07b553a",
        "v": "0x1",
        "yParity": "0x1",
        // Receipt fields
        "gasUsed": 21000n,
        "effectiveGasPrice": 17699339493n,
        "status": 1,
      },
    )
  })

  Async.it(
    "Successfully fetches ZKSync EIP-712 transactions (type 0x71) with optional signature fields",
    async () => {
      // Transaction from Abstract Testnet (ZKSync-based) that lacks r/s/v signature fields
      let testTransactionHash = "0x245134326b7fecdcb7e0ed0a6cf090fc8881a63420ecd329ef645686b85647ed"

      let client = Rest.client("https://api.testnet.abs.xyz")
      let getEventTransactionOrThrow = RpcSource.makeThrowingGetEventTransaction(
        ~getTransactionJson=async txHash =>
          switch await Rpc.GetTransactionByHash.rawRoute->Rest.fetch(txHash, ~client) {
          | Some(json) => json
          | None => Js.Exn.raiseError(`Transaction not found for hash: ${txHash}`)
          },
        ~getReceiptJson=neverGetReceiptJson,
        ~lowercaseAddresses=true,
      )

      // ZKSync EIP-712 transactions lack signature fields (v, r, s, yParity).
      // Per-field parsing handles this — absent fields are simply not included.
      Assert.deepEqual(
        await mockLog(~transactionHash=testTransactionHash)->getEventTransactionOrThrow(
          ~transactionSchema=S.schema(
            s =>
              {
                "hash": s.matches(S.string),
                "from": s.matches(Address.schema),
                "to": s.matches(Address.schema),
                "gas": s.matches(BigInt.nativeSchema),
                "gasPrice": s.matches(BigInt.nativeSchema),
                "nonce": s.matches(BigInt.nativeSchema),
                "value": s.matches(BigInt.nativeSchema),
                "type": s.matches(S.int),
                "maxFeePerGas": s.matches(BigInt.nativeSchema),
                "maxPriorityFeePerGas": s.matches(BigInt.nativeSchema),
              },
          ),
        ),
        {
          "hash": testTransactionHash,
          "from": "0x58027ecef16a9da81835a82cfc4afa1e729c74ff"->Address.unsafeFromString,
          "to": "0xd929e47c6e94cbf744fef53ecbc8e61f0f1ff73a"->Address.unsafeFromString,
          "gas": 1189904n,
          "gasPrice": 25000000n,
          "nonce": 662n,
          "value": 0n,
          "type": 113, // 0x71 = ZKSync EIP-712
          "maxFeePerGas": 25000000n,
          "maxPriorityFeePerGas": 0n,
        },
      )
    },
  )

  // Issue #931: Contract creation transactions have null `to` field.
  // Per-field parsing handles this — null fields are simply not included in the result.
  Async.it(
    "Contract creation transaction with null `to` field should parse successfully",
    async () => {
      // Mock a contract creation tx where `to` is null
      let getEventTransactionOrThrow = RpcSource.makeThrowingGetEventTransaction(
        ~getTransactionJson=_ =>
          Promise.resolve(
            %raw(`{"from": "0x95222290DD7278Aa3Ddd389Cc1E1d165CC4BAfe5", "to": null, "gas": "0x5208"}`),
          ),
        ~getReceiptJson=neverGetReceiptJson,
        ~lowercaseAddresses=false,
      )

      Assert.deepEqual(
        await mockLog()->getEventTransactionOrThrow(
          ~transactionSchema=S.schema(
            s =>
              {
                "from": s.matches(Address.schema),
                "gas": s.matches(BigInt.nativeSchema),
              },
          ),
        ),
        {
          "from": "0x95222290DD7278Aa3Ddd389Cc1E1d165CC4BAfe5"->Address.Evm.fromStringOrThrow,
          "gas": 21000n,
        },
      )
    },
  )

  // gasUsed, cumulativeGasUsed, and effectiveGasPrice are receipt-only fields.
  // Only the receipt JSON is fetched — transaction JSON is not needed.
  Async.it(
    "Fetches gasUsed from receipt only (no transaction call)",
    async () => {
      let getEventTransactionOrThrow = RpcSource.makeThrowingGetEventTransaction(
        ~getTransactionJson=neverGetTransactionJson,
        ~getReceiptJson=_ => Promise.resolve(%raw(`{"gasUsed": "0x5208"}`)),
        ~lowercaseAddresses=false,
      )

      Assert.deepEqual(
        await mockLog()->getEventTransactionOrThrow(
          ~transactionSchema=S.schema(
            s =>
              {
                "gasUsed": s.matches(BigInt.nativeSchema),
              },
          ),
        ),
        {"gasUsed": 21000n},
      )
    },
  )

  Async.it(
    "Fetches cumulativeGasUsed from receipt only (no transaction call)",
    async () => {
      let getEventTransactionOrThrow = RpcSource.makeThrowingGetEventTransaction(
        ~getTransactionJson=neverGetTransactionJson,
        ~getReceiptJson=_ => Promise.resolve(%raw(`{"cumulativeGasUsed": "0x7a120"}`)),
        ~lowercaseAddresses=false,
      )

      Assert.deepEqual(
        await mockLog()->getEventTransactionOrThrow(
          ~transactionSchema=S.schema(
            s =>
              {
                "cumulativeGasUsed": s.matches(BigInt.nativeSchema),
              },
          ),
        ),
        {"cumulativeGasUsed": 500000n},
      )
    },
  )

  Async.it(
    "Fetches effectiveGasPrice from receipt only (no transaction call)",
    async () => {
      let getEventTransactionOrThrow = RpcSource.makeThrowingGetEventTransaction(
        ~getTransactionJson=neverGetTransactionJson,
        ~getReceiptJson=_ => Promise.resolve(%raw(`{"effectiveGasPrice": "0x41ef67ce5"}`)),
        ~lowercaseAddresses=false,
      )

      Assert.deepEqual(
        await mockLog()->getEventTransactionOrThrow(
          ~transactionSchema=S.schema(
            s =>
              {
                "effectiveGasPrice": s.matches(BigInt.nativeSchema),
              },
          ),
        ),
        {"effectiveGasPrice": 17699339493n},
      )
    },
  )

  Async.it(
    "Fetches from both transaction and receipt when fields from both are needed",
    async () => {
      let getEventTransactionOrThrow = RpcSource.makeThrowingGetEventTransaction(
        ~getTransactionJson=_ =>
          Promise.resolve(%raw(`{"gas": "0x5208", "value": "0x3e8"}`)),
        ~getReceiptJson=_ =>
          Promise.resolve(
            %raw(`{"gasUsed": "0x5208", "effectiveGasPrice": "0x41ef67ce5", "status": "0x1"}`),
          ),
        ~lowercaseAddresses=false,
      )

      Assert.deepEqual(
        await mockLog()->getEventTransactionOrThrow(
          ~transactionSchema=S.schema(
            s =>
              {
                "hash": s.matches(S.string),
                "gas": s.matches(BigInt.nativeSchema),
                "gasUsed": s.matches(BigInt.nativeSchema),
                "effectiveGasPrice": s.matches(BigInt.nativeSchema),
                "status": s.matches(S.int),
              },
          ),
        ),
        {
          "hash": "0xabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdef",
          "gas": 21000n,
          "gasUsed": 21000n,
          "effectiveGasPrice": 17699339493n,
          "status": 1,
        },
      )
    },
  )

  Async.it(
    "Transaction-only fields don't call getReceiptJson",
    async () => {
      let getEventTransactionOrThrow = RpcSource.makeThrowingGetEventTransaction(
        ~getTransactionJson=_ =>
          Promise.resolve(%raw(`{"gas": "0x5208", "input": "0xdeadbeef"}`)),
        ~getReceiptJson=neverGetReceiptJson,
        ~lowercaseAddresses=false,
      )

      Assert.deepEqual(
        await mockLog()->getEventTransactionOrThrow(
          ~transactionSchema=S.schema(
            s =>
              {
                "gas": s.matches(BigInt.nativeSchema),
                "input": s.matches(S.string),
              },
          ),
        ),
        {
          "gas": 21000n,
          "input": "0xdeadbeef",
        },
      )
    },
  )

  Async.it(
    "Unknown extra fields in JSON don't cause failures",
    async () => {
      // The RPC response has many extra fields (blockHash, blockNumber, chainId, etc.)
      // that the user didn't request. These should be silently ignored.
      let getEventTransactionOrThrow = RpcSource.makeThrowingGetEventTransaction(
        ~getTransactionJson=_ =>
          Promise.resolve(
            %raw(`{
              "gas": "0x5208",
              "blockHash": "0xabc",
              "blockNumber": "0x1",
              "chainId": "0x1",
              "unknownField": "some value",
              "anotherUnknown": 42
            }`),
          ),
        ~getReceiptJson=neverGetReceiptJson,
        ~lowercaseAddresses=false,
      )

      Assert.deepEqual(
        await mockLog()->getEventTransactionOrThrow(
          ~transactionSchema=S.schema(
            s =>
              {
                "gas": s.matches(BigInt.nativeSchema),
              },
          ),
        ),
        {"gas": 21000n},
      )
    },
  )

  Async.it(
    "Fetches l1FeeScalar from receipt (decimal string, not hex)",
    async () => {
      let getEventTransactionOrThrow = RpcSource.makeThrowingGetEventTransaction(
        ~getTransactionJson=neverGetTransactionJson,
        ~getReceiptJson=_ => Promise.resolve(%raw(`{"l1FeeScalar": "0.684"}`)),
        ~lowercaseAddresses=false,
      )

      Assert.deepEqual(
        await mockLog()->getEventTransactionOrThrow(
          ~transactionSchema=S.schema(
            s =>
              {
                "l1FeeScalar": s.matches(S.float),
              },
          ),
        ),
        {"l1FeeScalar": 0.684},
      )
    },
  )

  Async.it("Error with a value not matching the field schema", async () => {
    let getEventTransactionOrThrow = RpcSource.makeThrowingGetEventTransaction(
      ~getTransactionJson=_ => Promise.resolve(%raw(`{"gas": "not-a-hex-value"}`)),
      ~getReceiptJson=neverGetReceiptJson,
      ~lowercaseAddresses=false,
    )
    try {
      let _ = await mockLog()->getEventTransactionOrThrow(
        ~transactionSchema=S.schema(
          s =>
            {
              "gas": s.matches(BigInt.nativeSchema),
            },
        ),
      )
      Assert.fail("Should have thrown")
    } catch {
    | Js.Exn.Error(e) =>
      Assert.equal(
        e->Js.Exn.message->Belt.Option.getExn,
        `Invalid transaction field "gas" found in the RPC response. Error: The string is not valid hex`,
      )
    }
  })

  Async.it("Address fields are normalized with lowercaseAddresses=true", async () => {
    let getEventTransactionOrThrow = RpcSource.makeThrowingGetEventTransaction(
      ~getTransactionJson=neverGetTransactionJson,
      ~getReceiptJson=_ =>
        Promise.resolve(
          %raw(`{"from": "0x95222290DD7278Aa3Ddd389Cc1E1d165CC4BAfe5", "contractAddress": "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"}`),
        ),
      ~lowercaseAddresses=true,
    )

    let result = await mockLog()->getEventTransactionOrThrow(
      ~transactionSchema=S.schema(
        s =>
          {
            "from": s.matches(Address.schema),
            "contractAddress": s.matches(Address.schema),
          },
      ),
    )
    Assert.deepEqual(
      result,
      {
        "from": "0x95222290dd7278aa3ddd389cc1e1d165cc4bafe5"->Address.unsafeFromString,
        "contractAddress": "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48"->Address.unsafeFromString,
      },
    )
  })
})

let chain = HyperSyncSource_test.chain
describe("RpcSource - getSelectionConfig", () => {
  let mockAddress0 = TestHelpers.Addresses.mockAddresses[0]

  it("Selection config for the most basic case with no wildcards", () => {
    let selectionConfig = {
      dependsOnAddresses: true,
      eventConfigs: [(Mock.evmEventConfig() :> Internal.eventConfig)],
    }->RpcSource.getSelectionConfig(~chain)

    Assert.deepEqual(
      selectionConfig.getLogSelectionOrThrow(
        ~addressesByContractName=Js.Dict.fromArray([("ERC20", [mockAddress0])]),
      ),
      {
        addresses: Some([mockAddress0]),
        topicQuery: [Single(Mock.eventId)],
      },
      ~message=`Should include only single topic0 address`,
    )
  })

  it("Selection config with wildcard events", () => {
    let selectionConfig = {
      dependsOnAddresses: false,
      eventConfigs: [
        (Mock.evmEventConfig(~id="1", ~isWildcard=true) :> Internal.eventConfig),
        (Mock.evmEventConfig(~id="2", ~isWildcard=true) :> Internal.eventConfig),
      ],
    }->RpcSource.getSelectionConfig(~chain)

    Assert.deepEqual(
      selectionConfig.getLogSelectionOrThrow(~addressesByContractName=Js.Dict.empty()),
      {
        addresses: None,
        topicQuery: [Multiple(["1", "2"])],
      },
      ~message=`Should include only topic0 addresses`,
    )
  })

  Async.it("Wildcard topic selection which depends on addresses", async () => {
    let selectionConfig = {
      dependsOnAddresses: false,
      eventConfigs: [
        (Mock.evmEventConfig(
          ~id="event 2",
          ~isWildcard=true,
          ~dependsOnAddresses=true,
        ) :> Internal.eventConfig),
      ],
    }->RpcSource.getSelectionConfig(~chain)

    Assert.deepEqual(
      selectionConfig.getLogSelectionOrThrow(
        ~addressesByContractName=Js.Dict.fromArray([("ERC20", [mockAddress0])]),
      ),
      {
        addresses: None,
        topicQuery: [Single("event 2"), Single(mockAddress0->Address.toString)],
      },
    )
  })

  Async.it("Non-wildcard topic selection which depends on addresses", async () => {
    let selectionConfig = {
      dependsOnAddresses: false,
      eventConfigs: [
        (Mock.evmEventConfig(
          ~id="event 2",
          ~isWildcard=false,
          ~dependsOnAddresses=true,
        ) :> Internal.eventConfig),
      ],
    }->RpcSource.getSelectionConfig(~chain)

    Assert.deepEqual(
      selectionConfig.getLogSelectionOrThrow(
        ~addressesByContractName=Js.Dict.fromArray([("ERC20", [mockAddress0])]),
      ),
      {
        addresses: Some([mockAddress0]),
        topicQuery: [Single("event 2"), Single(mockAddress0->Address.toString)],
      },
    )
  })

  it("Panics when selection has empty event configs", () => {
    try {
      let _ = {
        dependsOnAddresses: true,
        eventConfigs: [],
      }->RpcSource.getSelectionConfig(~chain)
      Assert.fail("Should have thrown")
    } catch {
    | Source.GetItemsError(UnsupportedSelection({message})) =>
      Assert.equal(
        message,
        "Invalid events configuration for the partition. Nothing to fetch. Please, report to the Envio team.",
      )
    | _ => Assert.fail("Should have thrown UnsupportedSelection")
    }
  })

  it("Panics when selection has normal event and event with filters", () => {
    try {
      let _ = {
        dependsOnAddresses: true,
        eventConfigs: [
          (Mock.evmEventConfig(~id="1") :> Internal.eventConfig),
          (Mock.evmEventConfig(~id="2", ~dependsOnAddresses=true) :> Internal.eventConfig),
        ],
      }->RpcSource.getSelectionConfig(~chain)
      Assert.fail("Should have thrown")
    } catch {
    | Source.GetItemsError(UnsupportedSelection({message})) =>
      Assert.equal(
        message,
        "RPC data-source currently supports event filters only when there's a single wildcard event. Please, create a GitHub issue if it's a blocker for you.",
      )
    | _ => Assert.fail("Should have thrown UnsupportedSelection")
    }
  })
})

describe("RpcSource - getSuggestedBlockIntervalFromExn", () => {
  let getSuggestedBlockIntervalFromExn = RpcSource.getSuggestedBlockIntervalFromExn

  it("Should handle retry with the range", () => {
    let error = JsError(
      %raw(`{
        "code": "UNKNOWN_ERROR",
        "error": {
          "code": -32602,
          "message": "query exceeds max results 20000, retry with the range 6000000-6000509"
        },
        "payload": {
          "method": "eth_getLogs",
          "params": [
            {
              "topics": [
                [
                  "0x8c5be1e5ebec7d5bd14f71427d1e84f3dd0314c0f7b2291e5b200ac8c7c3b925",
                  "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"
                ]
              ],
              "fromBlock": "0x5b8d80",
              "toBlock": "0x5b9168"
            }
          ],
          "id": 4,
          "jsonrpc": "2.0"
        },
        "shortMessage": "could not coalesce error"
    
      }`),
    )

    Assert.deepEqual(getSuggestedBlockIntervalFromExn(error), Some((510, false)))
  })

  it("Shouldn't retry on height not available", () => {
    let error = JsError(
      %raw(`{
        "code": "UNKNOWN_ERROR",
        "error": {
          "code": -32000,
          "message": "height is not available (requested height: 138913957, base height: 155251499)"
        },
        "payload": {
          "method": "eth_getBlockByNumber",
          "params": [
            "0x847a8a5",
            false
          ],
          "id": 2,
          "jsonrpc": "2.0"
        },
        "shortMessage": "could not coalesce error"
      }`),
    )

    Assert.deepEqual(getSuggestedBlockIntervalFromExn(error), None)
  })

  it("Should retry on block range too large", () => {
    let error = JsError(
      %raw(`{
        code: 'UNKNOWN_ERROR',
        error: {
          code: -32000,
          message: 'block range too large (2000), maximum allowed is 1000 blocks'
        },
        payload: { method: 'eth_getLogs', params: [], id: 4, jsonrpc: '2.0' },
        shortMessage: 'could not coalesce error'
      }`),
    )

    Assert.deepEqual(getSuggestedBlockIntervalFromExn(error), Some((1000, true)))
  })

  it("Should ignore invalid range errors where toBlock is less than fromBlock", () => {
    let error = JsError(
      %raw(`{
        "code": "UNKNOWN_ERROR",
        "error": {
          "code": -32602,
          "message": "query exceeds max results 20000, retry with the range 6000509-6000000"
        },
        "payload": {
          "method": "eth_getLogs",
          "params": [
            {
              "topics": [
                [
                  "0x8c5be1e5ebec7d5bd14f71427d1e84f3dd0314c0f7b2291e5b200ac8c7c3b925",
                  "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"
                ]
              ],
              "fromBlock": "0x5b8d80",
              "toBlock": "0x5b9168"
            }
          ],
          "id": 4,
          "jsonrpc": "2.0"
        },
        "shortMessage": "could not coalesce error"
    
      }`),
    )

    Assert.deepEqual(getSuggestedBlockIntervalFromExn(error), None)
  })

  it("Should handle block range limit from https://1rpc.io/eth", () => {
    let error = JsError(
      %raw(`{
        "code": "UNKNOWN_ERROR",
        "error": {
          "code": -32000,
          "message": "eth_getLogs is limited to a 1000 blocks range"
        },
        "payload": {
          "method": "eth_getLogs",
          "params": [
            {
              "address": "0xdac17f958d2ee523a2206206994597c13d831ec7", 
              "topics": [
                [
                  "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"
                ]
              ],
              "fromBlock": "0x5b8d80",
              "toBlock": "0x5ba17f"
            }
          ],
          "id": 18,
          "jsonrpc": "2.0"
        },
        "shortMessage": "could not coalesce error"
      }`),
    )

    Assert.deepEqual(getSuggestedBlockIntervalFromExn(error), Some((1000, true)))
  })

  it("Should handle block range limit from Alchemy", () => {
    let error = JsError(
      %raw(`{
        "code": "UNKNOWN_ERROR",
        "error": {
          "code": -32600,
          "message": "You can make eth_getLogs requests with up to a 500 block range. Based on your parameters, this block range should work: [0x3d7773, 0x3d7966]"
        },
        "payload": {
          "method": "eth_getLogs",
          "params": [
            {
              "address": "0x2da25e7446a70d7be65fd4c053948becaa6374c8",
              "topics": [
                "0x0d3648bd0f6ba80134a33ba9275ac585d9d315f0ad8355cddefde31afa28d0e9"
              ],
              "fromBlock": "0x3d7773",
              "toBlock": "0x3d843e"
            }
          ],
          "id": 13,
          "jsonrpc": "2.0"
        },
        "shortMessage": "could not coalesce error"
      }`),
    )

    Assert.deepEqual(getSuggestedBlockIntervalFromExn(error), Some((500, true)))
  })

  it("Should handle Rpc.JsonRpcError with block range limit", () => {
    let error = Rpc.JsonRpcError({
      code: -32000,
      message: "eth_getLogs is limited to a 1000 blocks range",
    })
    Assert.deepEqual(getSuggestedBlockIntervalFromExn(error), Some((1000, true)))
  })

  it("Should handle Rpc.JsonRpcError with suggested range", () => {
    let error = Rpc.JsonRpcError({
      code: -32602,
      message: "query exceeds max results 20000, retry with the range 6000000-6000509",
    })
    Assert.deepEqual(getSuggestedBlockIntervalFromExn(error), Some((510, false)))
  })
})
