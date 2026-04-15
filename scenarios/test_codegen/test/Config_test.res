open Vitest

// Exhaustiveness check: if a new variant is added to evmBlockField,
// this switch will fail to compile until it's added here.
// Each variant maps to a unique int so we can verify all are covered at runtime.
let blockFieldToInt = (field: Internal.evmBlockField) =>
  switch field {
  | Number => 1
  | Timestamp => 2
  | Hash => 3
  | ParentHash => 4
  | Nonce => 5
  | Sha3Uncles => 6
  | LogsBloom => 7
  | TransactionsRoot => 8
  | StateRoot => 9
  | ReceiptsRoot => 10
  | Miner => 11
  | Difficulty => 12
  | TotalDifficulty => 13
  | ExtraData => 14
  | Size => 15
  | GasLimit => 16
  | GasUsed => 17
  | Uncles => 18
  | BaseFeePerGas => 19
  | BlobGasUsed => 20
  | ExcessBlobGas => 21
  | ParentBeaconBlockRoot => 22
  | WithdrawalsRoot => 23
  | L1BlockNumber => 24
  | SendCount => 25
  | SendRoot => 26
  | MixHash => 27
  }

// Exhaustiveness check: if a new variant is added to evmTransactionField,
// this switch will fail to compile until it's added here.
let transactionFieldToInt = (field: Internal.evmTransactionField) =>
  switch field {
  | TransactionIndex => 1
  | Hash => 2
  | From => 3
  | To => 4
  | Gas => 5
  | GasPrice => 6
  | MaxPriorityFeePerGas => 7
  | MaxFeePerGas => 8
  | CumulativeGasUsed => 9
  | EffectiveGasPrice => 10
  | GasUsed => 11
  | Input => 12
  | Nonce => 13
  | Value => 14
  | V => 15
  | R => 16
  | S => 17
  | ContractAddress => 18
  | LogsBloom => 19
  | Root => 20
  | Status => 21
  | YParity => 22
  | AccessList => 23
  | MaxFeePerBlobGas => 24
  | BlobVersionedHashes => 25
  | Type => 26
  | L1Fee => 27
  | L1GasPrice => 28
  | L1GasUsed => 29
  | L1FeeScalar => 30
  | GasUsedForL1 => 31
  | AuthorizationList => 32
  }

// Compile-time exhaustiveness check: evmBlockConstructor must have a field for every evmBlockField variant.
// If a new variant is added to evmBlockField, this function will fail to compile until the constructor type is updated.
let _assertBlockConstructorCoversAllFields = (
  b: Internal.evmBlockInput,
  field: Internal.evmBlockField,
) =>
  switch field {
  | Number => b.number->ignore
  | Timestamp => b.timestamp->ignore
  | Hash => b.hash->ignore
  | ParentHash => b.parentHash->ignore
  | Nonce => b.nonce->ignore
  | Sha3Uncles => b.sha3Uncles->ignore
  | LogsBloom => b.logsBloom->ignore
  | TransactionsRoot => b.transactionsRoot->ignore
  | StateRoot => b.stateRoot->ignore
  | ReceiptsRoot => b.receiptsRoot->ignore
  | Miner => b.miner->ignore
  | Difficulty => b.difficulty->ignore
  | TotalDifficulty => b.totalDifficulty->ignore
  | ExtraData => b.extraData->ignore
  | Size => b.size->ignore
  | GasLimit => b.gasLimit->ignore
  | GasUsed => b.gasUsed->ignore
  | Uncles => b.uncles->ignore
  | BaseFeePerGas => b.baseFeePerGas->ignore
  | BlobGasUsed => b.blobGasUsed->ignore
  | ExcessBlobGas => b.excessBlobGas->ignore
  | ParentBeaconBlockRoot => b.parentBeaconBlockRoot->ignore
  | WithdrawalsRoot => b.withdrawalsRoot->ignore
  | L1BlockNumber => b.l1BlockNumber->ignore
  | SendCount => b.sendCount->ignore
  | SendRoot => b.sendRoot->ignore
  | MixHash => b.mixHash->ignore
  }

// Compile-time exhaustiveness check: evmTransactionConstructor must have a field for every evmTransactionField variant.
let _assertTransactionConstructorCoversAllFields = (
  tx: Internal.evmTransactionInput,
  field: Internal.evmTransactionField,
) =>
  switch field {
  | TransactionIndex => tx.transactionIndex->ignore
  | Hash => tx.hash->ignore
  | From => tx.from->ignore
  | To => tx.to->ignore
  | Gas => tx.gas->ignore
  | GasPrice => tx.gasPrice->ignore
  | MaxPriorityFeePerGas => tx.maxPriorityFeePerGas->ignore
  | MaxFeePerGas => tx.maxFeePerGas->ignore
  | CumulativeGasUsed => tx.cumulativeGasUsed->ignore
  | EffectiveGasPrice => tx.effectiveGasPrice->ignore
  | GasUsed => tx.gasUsed->ignore
  | Input => tx.input->ignore
  | Nonce => tx.nonce->ignore
  | Value => tx.value->ignore
  | V => tx.v->ignore
  | R => tx.r->ignore
  | S => tx.s->ignore
  | ContractAddress => tx.contractAddress->ignore
  | LogsBloom => tx.logsBloom->ignore
  | Root => tx.root->ignore
  | Status => tx.status->ignore
  | YParity => tx.yParity->ignore
  | AccessList => tx.accessList->ignore
  | MaxFeePerBlobGas => tx.maxFeePerBlobGas->ignore
  | BlobVersionedHashes => tx.blobVersionedHashes->ignore
  | Type => tx.type_->ignore
  | L1Fee => tx.l1Fee->ignore
  | L1GasPrice => tx.l1GasPrice->ignore
  | L1GasUsed => tx.l1GasUsed->ignore
  | L1FeeScalar => tx.l1FeeScalar->ignore
  | GasUsedForL1 => tx.gasUsedForL1->ignore
  | AuthorizationList => tx.authorizationList->ignore
  }

describe("Field selection enum schemas", () => {
  it("evmBlockFieldSchema covers all block field variants", t => {
    let sum = ref(0)
    Internal.allEvmBlockFields->Array.forEach(
      field => {
        let json = (field :> string)->JSON.Encode.string
        let parsed = json->S.parseOrThrow(Internal.evmBlockFieldSchema)
        sum := sum.contents + blockFieldToInt(parsed)
      },
    )
    // n*(n+1)/2 where n = 27
    t.expect(sum.contents).toBe(27 * 28 / 2)
  })

  it("evmTransactionFieldSchema covers all transaction field variants", t => {
    let sum = ref(0)
    Internal.allEvmTransactionFields->Array.forEach(
      field => {
        let json = (field :> string)->JSON.Encode.string
        let parsed = json->S.parseOrThrow(Internal.evmTransactionFieldSchema)
        sum := sum.contents + transactionFieldToInt(parsed)
      },
    )
    // n*(n+1)/2 where n = 32
    t.expect(sum.contents).toBe(32 * 33 / 2)
  })
})

describe("EventConfigBuilder", () => {
  it("buildParamsSchema handles simple types", t => {
    let params: array<EventConfigBuilder.eventParam> = [
      {name: "from", abiType: "address", indexed: true},
      {name: "to", abiType: "address", indexed: true},
      {name: "value", abiType: "uint256", indexed: false},
    ]
    let schema = EventConfigBuilder.buildParamsSchema(params)
    // Serialize a params object to JSON via the schema
    let testParams: Internal.eventParams =
      {"from": "0xabc", "to": "0xdef", "value": 100n}->Utils.magic
    let json = testParams->S.reverseConvertToJsonOrThrow(schema)
    t.expect(json).toEqual(%raw(`{"from": "0xabc", "to": "0xdef", "value": "100"}`))
  })

  it("buildParamsSchema handles empty params", t => {
    let schema = EventConfigBuilder.buildParamsSchema([])
    let testParams: Internal.eventParams = ()->Utils.magic
    let json = testParams->S.reverseConvertToJsonOrThrow(schema)
    t.expect(json).toEqual(%raw(`null`))
  })

  it("buildParamsSchema handles tuple params", t => {
    let params: array<EventConfigBuilder.eventParam> = [
      {name: "id", abiType: "uint256", indexed: false},
      {name: "details", abiType: "(string,string)", indexed: false},
    ]
    let schema = EventConfigBuilder.buildParamsSchema(params)
    let testParams: Internal.eventParams = {"id": 1n, "details": ("hello", "world")}->Utils.magic
    let json = testParams->S.reverseConvertToJsonOrThrow(schema)
    t.expect(json).toEqual(%raw(`{"id": "1", "details": ["hello", "world"]}`))
  })

  it("buildParamsSchema handles nested tuple params", t => {
    let params: array<EventConfigBuilder.eventParam> = [
      {name: "data", abiType: "(uint256,(uint256,string))", indexed: false},
    ]
    let schema = EventConfigBuilder.buildParamsSchema(params)
    let testParams: Internal.eventParams = {"data": (1n, (2n, "hello"))}->Utils.magic
    let json = testParams->S.reverseConvertToJsonOrThrow(schema)
    t.expect(json).toEqual(%raw(`{"data": ["1", ["2", "hello"]]}`))
  })

  it("buildParamsSchema handles array types", t => {
    let params: array<EventConfigBuilder.eventParam> = [
      {name: "ids", abiType: "uint256[]", indexed: false},
    ]
    let schema = EventConfigBuilder.buildParamsSchema(params)
    let testParams: Internal.eventParams = {"ids": [1n, 2n, 3n]}->Utils.magic
    let json = testParams->S.reverseConvertToJsonOrThrow(schema)
    t.expect(json).toEqual(%raw(`{"ids": ["1", "2", "3"]}`))
  })

  it("buildHyperSyncDecoder produces correct field names", t => {
    let params: array<EventConfigBuilder.eventParam> = [
      {name: "from", abiType: "address", indexed: true},
      {name: "to", abiType: "address", indexed: true},
      {name: "value", abiType: "uint256", indexed: false},
    ]
    let decoder = EventConfigBuilder.buildHyperSyncDecoder(params)
    // decodedRaw values are @unboxed - at JS level they're just the raw values
    let mockDecodedEvent: HyperSyncClient.Decoder.decodedEvent = {
      indexed: ["0xabc"->Utils.magic, "0xdef"->Utils.magic],
      body: [100n->Utils.magic],
    }
    let result = decoder(mockDecodedEvent)
    t.expect(result).toEqual({"from": "0xabc", "to": "0xdef", "value": 100n}->Utils.magic)
  })

  it("buildHyperSyncDecoder handles empty params", t => {
    let decoder = EventConfigBuilder.buildHyperSyncDecoder([])
    let mockDecodedEvent: HyperSyncClient.Decoder.decodedEvent = {
      indexed: [],
      body: [],
    }
    let result = decoder(mockDecodedEvent)
    t.expect(result).toEqual(()->Utils.magic)
  })

  it("schema and decoder field names are consistent", t => {
    let params: array<EventConfigBuilder.eventParam> = [
      {name: "id", abiType: "uint256", indexed: false},
      {name: "contactDetails", abiType: "(string,string)", indexed: false},
    ]
    let schema = EventConfigBuilder.buildParamsSchema(params)
    let decoder = EventConfigBuilder.buildHyperSyncDecoder(params)

    // Decoder produces an object with the correct field names
    let mockDecodedEvent: HyperSyncClient.Decoder.decodedEvent = {
      indexed: [],
      body: [42n->Utils.magic, ("Alice", "alice@example.com")->Utils.magic],
    }
    let decoded = decoder(mockDecodedEvent)

    // Schema can serialize the decoded result — proves field names match
    let json = decoded->S.reverseConvertToJsonOrThrow(schema)
    t.expect(json).toEqual(%raw(`{"id": "42", "contactDetails": ["Alice", "alice@example.com"]}`))
  })

  it("buildHyperSyncDecoder remaps mixed-name tuple components using index keys", t => {
    // Issue #538 follow-up: when a tuple has some named and some unnamed
    // components, the CLI emits `"0"`, `"1"`, ... for unnamed slots. The
    // runtime decoder must honour those keys so handlers can access unnamed
    // fields via `value["1"]`.
    let params: array<EventConfigBuilder.eventParam> = [
      {
        name: "mixed",
        abiType: "(string,uint256,address,bool)",
        indexed: false,
        components: [
          {name: "label", abiType: "string"},
          {name: "1", abiType: "uint256"},
          {name: "recipient", abiType: "address"},
          {name: "3", abiType: "bool"},
        ],
      },
    ]
    let decoder = EventConfigBuilder.buildHyperSyncDecoder(params)
    let mockDecodedEvent: HyperSyncClient.Decoder.decodedEvent = {
      indexed: [],
      body: [
        ("hi", 42n, "0xabc", true)->(
          Utils.magic: ((string, bigint, string, bool)) => HyperSyncClient.Decoder.decodedRaw
        ),
      ],
    }
    let decoded = decoder(mockDecodedEvent)
    t.expect(decoded).toEqual(
      {"mixed": {"label": "hi", "1": 42n, "recipient": "0xabc", "3": true}}->(
        Utils.magic: {..} => Internal.eventParams
      ),
    )
  })

  it("buildHyperSyncDecoder leaves indexed struct params as topic hashes", t => {
    // Indexed structs/tuples are delivered as keccak256 topic hashes (single
    // hex strings), not positional arrays. Even if `components` metadata is
    // present, the decoder must NOT try to rebuild a named record from them —
    // doing so would treat the hash as an array and read garbage.
    let params: array<EventConfigBuilder.eventParam> = [
      {
        name: "indexedStruct",
        abiType: "(address,uint256)",
        indexed: true,
        components: [
          {name: "owner", abiType: "address"},
          {name: "amount", abiType: "uint256"},
        ],
      },
    ]
    let decoder = EventConfigBuilder.buildHyperSyncDecoder(params)
    let topicHash = "0xdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
    let mockDecodedEvent: HyperSyncClient.Decoder.decodedEvent = {
      indexed: [topicHash->(Utils.magic: string => HyperSyncClient.Decoder.decodedRaw)],
      body: [],
    }
    let decoded = decoder(mockDecodedEvent)
    t.expect(decoded).toEqual(
      {"indexedStruct": topicHash}->(Utils.magic: {..} => Internal.eventParams),
    )
  })

  it("abiTypeToSchema throws on unsupported types", t => {
    t.expect(() => EventConfigBuilder.abiTypeToSchema("function")).toThrowError(
      "Unsupported ABI type: function",
    )
  })
})

describe("Config.fromPublic", () => {
  it("resolves ABI for lowercase contract name in internal config", t => {
    // Internal config JSON with a lowercase contract name key ("greeter")
    // Addresses are now in per-chain contract data
    let publicConfigJson: JSON.t = %raw(`{
      "version": "0.0.1-dev",
      "name": "test",
      "evm": {
        "chains": {
          "ethereumMainnet": {
            "id": 1,
            "startBlock": 0,
            "rpcs": [{ "url": "https://eth.com", "for": "sync" }],
            "contracts": {
              "Greeter": {
                "addresses": ["0x0000000000000000000000000000000000000001"]
              }
            }
          }
        },
        "contracts": {
          "greeter": {
            "abi": [{"type":"event","name":"NewGreeting","inputs":[],"anonymous":false}],
            "events": [{ "event": "NewGreeting()", "name": "NewGreeting", "sighash": "0x00000000" }]
          }
        },
        "addressFormat": "checksum"
      }
    }`)

    // This should not throw - the fix capitalizes the internal config key
    // before lookup, so "greeter" -> "Greeter" matches the chain contract name
    let config = Config.fromPublic(publicConfigJson)

    let chain = config.chainMap->ChainMap.values->Array.getUnsafe(0)
    let contracts = chain.contracts
    t.expect(contracts->Array.length, ~message="Should have one contract").toBe(1)
    let contract = contracts->Array.getUnsafe(0)
    t.expect(contract.name, ~message="Contract name should be the capitalized version").toBe(
      "Greeter",
    )
  })

  it("works with already-capitalized contract name", t => {
    let publicConfigJson: JSON.t = %raw(`{
      "version": "0.0.1-dev",
      "name": "test",
      "evm": {
        "chains": {
          "ethereumMainnet": {
            "id": 1,
            "startBlock": 0,
            "rpcs": [{ "url": "https://eth.com", "for": "sync" }],
            "contracts": {
              "Greeter": {
                "addresses": ["0x0000000000000000000000000000000000000001"]
              }
            }
          }
        },
        "contracts": {
          "Greeter": {
            "abi": [{"type":"event","name":"NewGreeting","inputs":[],"anonymous":false}],
            "events": [{ "event": "NewGreeting()", "name": "NewGreeting", "sighash": "0x00000000" }]
          }
        },
        "addressFormat": "checksum"
      }
    }`)

    let config = Config.fromPublic(publicConfigJson)

    let chain = config.chainMap->ChainMap.values->Array.getUnsafe(0)
    let contracts = chain.contracts
    t.expect(contracts->Array.length, ~message="Should have one contract").toBe(1)
    let contract = contracts->Array.getUnsafe(0)
    t.expect(contract.name, ~message="Contract name should remain Greeter").toBe("Greeter")
  })
})
