open RescriptMocha

let testApiToken = "3dc856dd-b0ea-494f-b27e-017b8b6b7e07"

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

describe("RpcSource - name", () => {
  it("Returns the name of the source including sanitized rpc url", () => {
    let source = RpcSource.make({
      url: "https://eth.rpc.hypersync.xyz?api_key=123",
      chain: MockConfig.chain1337,
      contracts: [],
      eventRouter: EventRouter.empty(),
      sourceFor: Sync,
      syncConfig: EvmChain.getSyncConfig({}),
      allEventSignatures: [],
      shouldUseHypersyncClientDecoder: false,
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
      contracts: [],
      eventRouter: EventRouter.empty(),
      sourceFor: Sync,
      syncConfig: EvmChain.getSyncConfig({}),
      allEventSignatures: ["a", "b", "c"],
      shouldUseHypersyncClientDecoder: true,
      lowercaseAddresses: false,
    })
    let height = await source.getHeightOrThrow()
    Assert.equal(height > 21994218, true)
    Assert.equal(height < 30000000, true)
  })
})

describe("RpcSource - getEventTransactionOrThrow", () => {
  let neverGetTransactionFields = _ => Assert.fail("The getTransactionFields should not be called")

  it("Panics with invalid schema", () => {
    Assert.throws(
      () => {
        RpcSource.makeThrowingGetEventTransaction(~getTransactionFields=neverGetTransactionFields)(
          mockEthersLog(),
          ~transactionSchema=S.string,
        )
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
        ~getTransactionFields=neverGetTransactionFields,
      )
      Assert.deepEqual(
        await mockEthersLog()->getEventTransactionOrThrow(~transactionSchema=S.object(_ => ())),
        %raw(`{}`),
      )
    },
  )

  Async.it("Works with a single transactionIndex field", async () => {
    let getEventTransactionOrThrow = RpcSource.makeThrowingGetEventTransaction(
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
    let getEventTransactionOrThrow = RpcSource.makeThrowingGetEventTransaction(
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
    let getEventTransactionOrThrow = RpcSource.makeThrowingGetEventTransaction(
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
    let getEventTransactionOrThrow = RpcSource.makeThrowingGetEventTransaction(
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

    let rpcUrl = `https://eth.rpc.hypersync.xyz/${testApiToken}`
    let client = Rest.client(rpcUrl)
    let getTransactionFields = Ethers.JsonRpcProvider.makeGetTransactionFields(
      ~getTransactionByHash=async transactionHash =>
        switch await Rpc.GetTransactionByHash.route->Rest.fetch(transactionHash, ~client) {
        | Some(tx) => tx
        | None => Js.Exn.raiseError(`Transaction not found for hash: ${transactionHash}`)
        },
      ~lowercaseAddresses=false,
    )

    let getEventTransactionOrThrow = RpcSource.makeThrowingGetEventTransaction(
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
              "gas": s.matches(BigInt.nativeSchema),
              "gasPrice": s.matches(S.option(BigInt.nativeSchema)),
              "maxPriorityFeePerGas": s.matches(S.option(BigInt.nativeSchema)),
              "maxFeePerGas": s.matches(S.option(BigInt.nativeSchema)),
              // "cumulativeGasUsed": s.matches(BigInt.nativeSchema), // --- Invalid transaction field "cumulativeGasUsed" found in the RPC response. Error: Expected bigint
              // "effectiveGasPrice": s.matches(BigInt.nativeSchema), // --- Invalid transaction field "effectiveGasPrice" found in the RPC response. Error: Expected bigint
              // "gasUsed": s.matches(BigInt.nativeSchema), // --- Invalid transaction field "gasUsed" found in the RPC response. Error: Expected bigint
              "input": s.matches(S.string),
              "nonce": s.matches(BigInt.nativeSchema),
              "value": s.matches(BigInt.nativeSchema),
              "v": s.matches(S.option(S.string)),
              "r": s.matches(S.option(S.string)),
              "s": s.matches(S.option(S.string)),
              "yParity": s.matches(S.option(S.string)),
              "contractAddress": s.matches(S.option(Address.schema)),
              // "logsBloom": s.matches(S.string), // --- Invalid transaction field "logsBloom" found in the RPC response. Error: Expected String, received undefined
              "root": s.matches(S.option(S.string)),
              "status": s.matches(S.option(S.int)),
              "chainId": s.matches(S.option(S.int)),
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
        "gas": 21000n,
        "maxPriorityFeePerGas": Some(0n),
        "maxFeePerGas": Some(17699339493n),
        "input": "0x",
        "nonce": 1722147n,
        "value": 34302998902926621n,
        "r": Some("0xb73e53731ff8484f3c30c2850328f0ad7ca5a8dd8681d201ba52777aaf972f87"),
        "s": Some("0x10c1bcf56abfb5dc6dae06e1c0e441b68068fc23064364eaf0ae3e76e07b553a"),
        "v": Some("0x1"),
        "contractAddress": None,
        "root": None,
        "status": None,
        "yParity": Some("0x1"),
        "chainId": Some(1),
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
  })

  Async.it(
    "Successfully fetches ZKSync EIP-712 transactions (type 0x71) with optional signature fields",
    async () => {
      // Transaction from Abstract Testnet (ZKSync-based) that lacks r/s/v signature fields
      let testTransactionHash = "0x245134326b7fecdcb7e0ed0a6cf090fc8881a63420ecd329ef645686b85647ed"

      let client = Rest.client("https://api.testnet.abs.xyz")
      let transaction =
        await Rpc.GetTransactionByHash.route->Rest.fetch(testTransactionHash, ~client)

      // Transaction should be fetched successfully
      Assert.ok(transaction->Belt.Option.isSome, ~message="Transaction should be fetched")
      let tx = transaction->Belt.Option.getUnsafe

      tx->Utils.Dict.unsafeDeleteUndefinedFieldsInPlace

      // Verify all transaction fields using a single comparison
      // ZKSync EIP-712 transactions lack signature fields (v, r, s, yParity)
      Assert.deepEqual(
        tx,
        {
          hash: testTransactionHash,
          blockHash: "0x75f6c2fcedf597b750ee1f960794906a3795d5894ea7af6400334ca2e86109f8",
          blockNumber: 9290261,
          from: "0x58027ecef16a9da81835a82cfc4afa1e729c74ff"->Address.unsafeFromString,
          to: "0xd929e47c6e94cbf744fef53ecbc8e61f0f1ff73a"->Address.unsafeFromString,
          gas: 1189904n,
          gasPrice: 25000000n,
          input: "0xfe939afc000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000061",
          nonce: 662n,
          transactionIndex: 0,
          value: 0n,
          type_: 113, // 0x71 = ZKSync EIP-712
          maxFeePerGas: 25000000n,
          maxPriorityFeePerGas: 0n,
          chainId: 11124,
        },
      )
    },
  )

  Async.it("Error with a value not matching the schema", async () => {
    let getEventTransactionOrThrow = RpcSource.makeThrowingGetEventTransaction(
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
        "message": `Invalid transaction field "hash" found in the RPC response. Error: Expected int32, received "0xabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdef"`,
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
})
