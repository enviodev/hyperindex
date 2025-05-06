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

describe("RpcSource - name", () => {
  it("Returns the name of the source including sanitized rpc url", () => {
    let source = RpcSource.make({
      url: "https://eth.rpc.hypersync.xyz?api_key=123",
      chain: MockConfig.chain1337,
      contracts: [],
      eventRouter: EventRouter.empty(),
      sourceFor: Sync,
      syncConfig: Config.getSyncConfig({}),
    })
    Assert.equal(source.name, "RPC (eth.rpc.hypersync.xyz)")
  })
})

describe("RpcSource - getHeightOrThrow", () => {
  Async.it("Returns the name of the source including sanitized rpc url", async () => {
    let source = RpcSource.make({
      url: "https://eth.rpc.hypersync.xyz",
      chain: MockConfig.chain1337,
      contracts: [],
      eventRouter: EventRouter.empty(),
      sourceFor: Sync,
      syncConfig: Config.getSyncConfig({}),
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

  Async.it_only(
    "Queries transaction with a non-log field (with real Ethers.provider)",
    async () => {
      let testTransactionHash = "0x3dce529e9661cfb65defa88ae5cd46866ddf39c9751d89774d89728703c2049f"

      let provider = Ethers.JsonRpcProvider.make(
        ~rpcUrl="https://eth.rpc.hypersync.xyz",
        ~chainId=1,
      )
      let getTransactionFields = Ethers.JsonRpcProvider.makeGetTransactionFields(
        ~getTransactionByHash=transactionHash =>
          provider->Ethers.JsonRpcProvider.getTransaction(~transactionHash),
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

    Assert.deepEqual(getSuggestedBlockIntervalFromExn(error), Some(510))
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

    Assert.deepEqual(getSuggestedBlockIntervalFromExn(error), Some(1000))
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

    Assert.deepEqual(getSuggestedBlockIntervalFromExn(error), Some(500))
  })
})
