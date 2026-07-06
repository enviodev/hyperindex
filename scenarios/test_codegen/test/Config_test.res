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

describe("svmEventDescriptorSchema", () => {
  // Regression: the schema must declare `blockFields`. rescript-schema strips
  // undeclared keys on parse, so a missing declaration silently drops SVM
  // block-field selection before it reaches the event config.
  it("preserves blockFields through parse", t => {
    let json: JSON.t = %raw(`{
      "discriminator": "0x21",
      "discriminatorByteLen": 1,
      "transactionFields": [],
      "blockFields": ["height", "parentSlot", "parentHash"],
      "includeLogs": false
    }`)
    let parsed = json->S.parseOrThrow(Config.svmEventDescriptorSchema)
    let expected: option<array<Internal.svmBlockField>> = Some([Height, ParentSlot, ParentHash])
    t.expect(parsed["blockFields"]).toEqual(expected)
  })
})

describe("EventConfigBuilder", () => {
  it("buildParamsSchema handles simple types", t => {
    let params: array<EventConfigBuilder.paramMeta> = [
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
    let params: array<EventConfigBuilder.paramMeta> = [
      {name: "id", abiType: "uint256", indexed: false},
      {name: "details", abiType: "(string,string)", indexed: false},
    ]
    let schema = EventConfigBuilder.buildParamsSchema(params)
    let testParams: Internal.eventParams = {"id": 1n, "details": ("hello", "world")}->Utils.magic
    let json = testParams->S.reverseConvertToJsonOrThrow(schema)
    t.expect(json).toEqual(%raw(`{"id": "1", "details": ["hello", "world"]}`))
  })

  it("buildParamsSchema handles nested tuple params", t => {
    let params: array<EventConfigBuilder.paramMeta> = [
      {name: "data", abiType: "(uint256,(uint256,string))", indexed: false},
    ]
    let schema = EventConfigBuilder.buildParamsSchema(params)
    let testParams: Internal.eventParams = {"data": (1n, (2n, "hello"))}->Utils.magic
    let json = testParams->S.reverseConvertToJsonOrThrow(schema)
    t.expect(json).toEqual(%raw(`{"data": ["1", ["2", "hello"]]}`))
  })

  it("buildParamsSchema handles array types", t => {
    let params: array<EventConfigBuilder.paramMeta> = [
      {name: "ids", abiType: "uint256[]", indexed: false},
    ]
    let schema = EventConfigBuilder.buildParamsSchema(params)
    let testParams: Internal.eventParams = {"ids": [1n, 2n, 3n]}->Utils.magic
    let json = testParams->S.reverseConvertToJsonOrThrow(schema)
    t.expect(json).toEqual(%raw(`{"ids": ["1", "2", "3"]}`))
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
      "storage": { "postgres": true },
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

  // Locks fromPublic against silently dropping low bits — the ERC20
  // silent-skip bug came from an f64-truncated address being sent to
  // HyperSync, where every event query then returned zero matches.
  it("preserves full 20-byte hex address through fromPublic", t => {
    let uni = "0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984"
    let publicConfigJson: JSON.t = %raw(`{
      "version": "0.0.1-dev",
      "name": "test",
      "storage": { "postgres": true },
      "evm": {
        "chains": {
          "ethereumMainnet": {
            "id": 1,
            "startBlock": 0,
            "rpcs": [{ "url": "https://eth.com", "for": "sync" }],
            "contracts": {
              "ERC20": {
                "addresses": ["0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984"]
              }
            }
          }
        },
        "contracts": {
          "ERC20": {
            "abi": [{"type":"event","name":"Transfer","inputs":[],"anonymous":false}],
            "events": [{ "event": "Transfer()", "name": "Transfer", "sighash": "0x00000000" }]
          }
        },
        "addressFormat": "checksum"
      }
    }`)

    let config = Config.fromPublic(publicConfigJson)
    let chain = config.chainMap->ChainMap.values->Array.getUnsafe(0)
    let contract = chain.contracts->Array.getUnsafe(0)
    let address = contract.addresses->Array.getUnsafe(0)
    t.expect(address->Address.toString, ~message="Address must be preserved verbatim").toBe(uni)
  })

  // Builds a minimal single-chain, single-contract public config with one
  // configurable contract address, for exercising address_format handling.
  let makeAddressFormatConfigJson = (~addressFormat: string, ~address: string): JSON.t =>
    JSON.parseOrThrow(`{
      "version": "0.0.1-dev",
      "name": "test",
      "storage": { "postgres": true },
      "evm": {
        "chains": {
          "ethereumMainnet": {
            "id": 1,
            "startBlock": 0,
            "rpcs": [{ "url": "https://eth.com", "for": "sync" }],
            "contracts": {
              "ERC20": {
                "addresses": ["${address}"]
              }
            }
          }
        },
        "contracts": {
          "ERC20": {
            "abi": [{"type":"event","name":"Transfer","inputs":[],"anonymous":false}],
            "events": [{ "event": "Transfer()", "name": "Transfer", "sighash": "0x00000000" }]
          }
        },
        "addressFormat": "${addressFormat}"
      }
    }`)

  let getFirstContractAddress = (config: Config.t): string => {
    let chain = config.chainMap->ChainMap.values->Array.getUnsafe(0)
    let contract = chain.contracts->Array.getUnsafe(0)
    contract.addresses->Array.getUnsafe(0)->Address.toString
  }

  // config.yaml addresses go through the strict parser (Address.Evm.fromStringOrThrow /
  // fromStringLowercaseOrThrow), unlike simulate's srcAddress which only requires a
  // "0x" prefix. A malformed address here must still fail config load.
  it("throws when a contract address in config is not a valid 20-byte hex address (checksum format)", t => {
    t.expect(
      () =>
        Config.fromPublic(
          makeAddressFormatConfigJson(~addressFormat="checksum", ~address="0xfoo"),
        )->ignore,
    ).toThrowError(`Address "0xfoo" is invalid. Expected a 20-byte hex string starting with 0x.`)
  })

  it("throws when a contract address in config is not a valid 20-byte hex address (lowercase format)", t => {
    t.expect(
      () =>
        Config.fromPublic(
          makeAddressFormatConfigJson(~addressFormat="lowercase", ~address="0xfoo"),
        )->ignore,
    ).toThrowError(`Address "0xfoo" is invalid. Expected a 20-byte hex string starting with 0x.`)
  })

  // Whatever casing a valid 20-byte address is written in, address_format
  // adjusts it internally instead of rejecting it — that's the whole point of
  // the setting: don't make the user care about case.
  [
    ("checksum", "0xa2f6e6029638ccb484a2ccb6414499ad3e825cac", "all-lowercase"),
    ("checksum", "0xA2F6E6029638CCB484A2CCB6414499AD3E825CAC", "all-uppercase"),
    ("lowercase", "0xa2f6e6029638ccb484a2ccb6414499ad3e825cac", "all-lowercase"),
    ("lowercase", "0xA2F6E6029638CCB484A2CCB6414499AD3E825CAC", "all-uppercase"),
  ]->Array.forEach(((addressFormat, address, caseDescription)) => {
    it(`normalizes a ${caseDescription} address under address_format: ${addressFormat}`, t => {
      let config = Config.fromPublic(makeAddressFormatConfigJson(~addressFormat, ~address))
      t.expect(config->getFirstContractAddress).toBe(
        switch addressFormat {
        | "lowercase" => "0xa2f6e6029638ccb484a2ccb6414499ad3e825cac"
        | _ => "0xa2F6E6029638cCb484A2ccb6414499aD3e825CaC"
        },
      )
    })
  })

  it("parses entity and field descriptions from public config", t => {
    let publicConfigJson: JSON.t = %raw(`{
      "version": "0.0.1-dev",
      "name": "test",
      "storage": { "postgres": true },
      "evm": {
        "chains": {
          "ethereumMainnet": {
            "id": 1,
            "startBlock": 0,
            "rpcs": [{ "url": "https://eth.com", "for": "sync" }]
          }
        },
        "addressFormat": "checksum"
      },
      "enums": {},
      "entities": [{
        "name": "User",
        "description": "A user of the protocol",
        "properties": [
          { "name": "id", "type": "string", "description": "The user's address" },
          { "name": "balance", "type": "bigint" }
        ],
        "derivedFields": [
          {
            "fieldName": "tokens",
            "derivedFromEntity": "Token",
            "derivedFromField": "owner",
            "description": "Tokens owned by this user"
          }
        ]
      }]
    }`)

    let config = Config.fromPublic(publicConfigJson)
    let userEntity = config.userEntities->Array.getUnsafe(0)
    t.expect({
      "tableDescription": userEntity.table.description,
      "idDescription": switch userEntity.table.fields->Array.getUnsafe(0) {
      | Table.Field(f) => f.description
      | _ => None
      },
      "balanceDescription": switch userEntity.table.fields->Array.getUnsafe(1) {
      | Table.Field(f) => f.description
      | _ => None
      },
      "derivedDescription": switch userEntity.table.fields->Array.getUnsafe(2) {
      | Table.DerivedFrom(f) => f.description
      | _ => None
      },
    }).toEqual({
      "tableDescription": Some("A user of the protocol"),
      "idDescription": Some("The user's address"),
      "balanceDescription": None,
      "derivedDescription": Some("Tokens owned by this user"),
    })
  })

  it("resolves entity storage from the entity config, falling back to the global storage", t => {
    let publicConfigJson: JSON.t = %raw(`{
      "version": "0.0.1-dev",
      "name": "test",
      "storage": { "postgres": true, "clickhouse": true },
      "evm": {
        "chains": {
          "ethereumMainnet": {
            "id": 1,
            "startBlock": 0,
            "rpcs": [{ "url": "https://eth.com", "for": "sync" }]
          }
        },
        "addressFormat": "checksum"
      },
      "enums": {},
      "entities": [
        {
          "name": "User",
          "properties": [{ "name": "id", "type": "string" }]
        },
        {
          "name": "Snapshot",
          "storage": { "clickhouse": true },
          "properties": [{ "name": "id", "type": "string" }]
        }
      ]
    }`)

    let config = Config.fromPublic(publicConfigJson)
    t.expect(config.userEntities->Array.map(e => (e.name, e.storage))).toEqual([
      ("User", {Internal.postgres: true, clickhouse: true}),
      ("Snapshot", {Internal.postgres: false, clickhouse: true}),
    ])
  })

  // Guards against the opaque `duplicate key value violates unique constraint
  // "envio_addresses_pkey"` failure at storage init: envio_addresses is keyed
  // by (chainId, address), so the same address under two contract definitions
  // on one chain must be rejected at config load with the offending pair.
  it("throws when the same address is configured for two contracts on one chain", t => {
    let publicConfigJson: JSON.t = %raw(`{
      "version": "0.0.1-dev",
      "name": "test",
      "storage": { "postgres": true },
      "evm": {
        "chains": {
          "ethereumMainnet": {
            "id": 1,
            "startBlock": 0,
            "rpcs": [{ "url": "https://eth.com", "for": "sync" }],
            "contracts": {
              "AaveToken": {
                "addresses": ["0x7Fc66500c84A76Ad7e9c93437bFc5Ac33E2DDaE9"]
              },
              "AaveV3": {
                "addresses": ["0x7fc66500c84a76ad7e9c93437bfc5ac33e2ddae9"]
              }
            }
          }
        },
        "contracts": {
          "AaveToken": {
            "abi": [{"type":"event","name":"Transfer","inputs":[],"anonymous":false}],
            "events": [{ "event": "Transfer()", "name": "Transfer", "sighash": "0x00000000" }]
          },
          "AaveV3": {
            "abi": [{"type":"event","name":"DelegateChanged","inputs":[],"anonymous":false}],
            "events": [{ "event": "DelegateChanged()", "name": "DelegateChanged", "sighash": "0x00000001" }]
          }
        },
        "addressFormat": "checksum"
      }
    }`)

    t.expect(() => Config.fromPublic(publicConfigJson)->ignore).toThrowError(
      "Address 0x7Fc66500c84A76Ad7e9c93437bFc5Ac33E2DDaE9 on chain 1 is configured for multiple contracts: AaveToken and AaveV3. Indexing the same address with multiple contract definitions is not supported. Please define the events on a single contract definition instead.",
    )
  })

  it("throws when the same address is listed twice for one contract", t => {
    let publicConfigJson: JSON.t = %raw(`{
      "version": "0.0.1-dev",
      "name": "test",
      "storage": { "postgres": true },
      "evm": {
        "chains": {
          "ethereumMainnet": {
            "id": 1,
            "startBlock": 0,
            "rpcs": [{ "url": "https://eth.com", "for": "sync" }],
            "contracts": {
              "AaveToken": {
                "addresses": [
                  "0x7Fc66500c84A76Ad7e9c93437bFc5Ac33E2DDaE9",
                  "0x7fc66500c84a76ad7e9c93437bfc5ac33e2ddae9"
                ]
              }
            }
          }
        },
        "contracts": {
          "AaveToken": {
            "abi": [{"type":"event","name":"Transfer","inputs":[],"anonymous":false}],
            "events": [{ "event": "Transfer()", "name": "Transfer", "sighash": "0x00000000" }]
          }
        },
        "addressFormat": "checksum"
      }
    }`)

    t.expect(() => Config.fromPublic(publicConfigJson)->ignore).toThrowError(
      "Address 0x7Fc66500c84A76Ad7e9c93437bFc5Ac33E2DDaE9 is listed multiple times for the contract AaveToken on chain 1. Please remove the duplicate from your config.",
    )
  })

  it("allows the same address on different chains", t => {
    let publicConfigJson: JSON.t = %raw(`{
      "version": "0.0.1-dev",
      "name": "test",
      "storage": { "postgres": true },
      "evm": {
        "chains": {
          "ethereumMainnet": {
            "id": 1,
            "startBlock": 0,
            "rpcs": [{ "url": "https://eth.com", "for": "sync" }],
            "contracts": {
              "AaveToken": {
                "addresses": ["0x7Fc66500c84A76Ad7e9c93437bFc5Ac33E2DDaE9"]
              }
            }
          },
          "polygon": {
            "id": 137,
            "startBlock": 0,
            "rpcs": [{ "url": "https://polygon.com", "for": "sync" }],
            "contracts": {
              "AaveToken": {
                "addresses": ["0x7Fc66500c84A76Ad7e9c93437bFc5Ac33E2DDaE9"]
              }
            }
          }
        },
        "contracts": {
          "AaveToken": {
            "abi": [{"type":"event","name":"Transfer","inputs":[],"anonymous":false}],
            "events": [{ "event": "Transfer()", "name": "Transfer", "sighash": "0x00000000" }]
          }
        },
        "addressFormat": "checksum"
      }
    }`)

    let config = Config.fromPublic(publicConfigJson)
    t.expect(config.chainMap->ChainMap.values->Array.length).toBe(2)
  })

  it("works with already-capitalized contract name", t => {
    let publicConfigJson: JSON.t = %raw(`{
      "version": "0.0.1-dev",
      "name": "test",
      "storage": { "postgres": true },
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
