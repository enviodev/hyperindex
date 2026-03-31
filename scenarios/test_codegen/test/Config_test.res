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

describe("Field selection enum schemas", () => {
  it("evmBlockFieldSchema covers all block field variants", t => {
    let sum = ref(0)
    Internal.allEvmBlockFields->Js.Array2.forEach(field => {
      let json = (field :> string)->Js.Json.string
      let parsed = json->S.parseOrThrow(Internal.evmBlockFieldSchema)
      sum := sum.contents + blockFieldToInt(parsed)
    })
    // n*(n+1)/2 where n = 27
    t.expect(sum.contents).toBe(27 * 28 / 2)
  })

  it("evmTransactionFieldSchema covers all transaction field variants", t => {
    let sum = ref(0)
    Internal.allEvmTransactionFields->Js.Array2.forEach(field => {
      let json = (field :> string)->Js.Json.string
      let parsed = json->S.parseOrThrow(Internal.evmTransactionFieldSchema)
      sum := sum.contents + transactionFieldToInt(parsed)
    })
    // n*(n+1)/2 where n = 32
    t.expect(sum.contents).toBe(32 * 33 / 2)
  })
})

describe("Config.fromPublic", () => {
  it("resolves ABI for lowercase contract name in internal config", t => {
    // Internal config JSON with a lowercase contract name key ("greeter")
    // Addresses are now in per-chain contract data
    let publicConfigJson: Js.Json.t = %raw(`{
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

    let chain = config.chainMap->ChainMap.values->Js.Array2.unsafe_get(0)
    let contracts = chain.contracts
    t.expect(contracts->Array.length, ~message="Should have one contract").toBe(1)
    let contract = contracts->Js.Array2.unsafe_get(0)
    t.expect(
      contract.name,
      ~message="Contract name should be the capitalized version",
    ).toBe("Greeter")
  })

  it("works with already-capitalized contract name", t => {
    let publicConfigJson: Js.Json.t = %raw(`{
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

    let chain = config.chainMap->ChainMap.values->Js.Array2.unsafe_get(0)
    let contracts = chain.contracts
    t.expect(contracts->Array.length, ~message="Should have one contract").toBe(1)
    let contract = contracts->Js.Array2.unsafe_get(0)
    t.expect(
      contract.name,
      ~message="Contract name should remain Greeter",
    ).toBe("Greeter")
  })
})
