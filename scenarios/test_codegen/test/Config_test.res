open Vitest

// Exhaustiveness check: if a new variant is added to evmBlockField,
// this match will fail to compile until it's added here and to the schema.
let checkBlockField = (field: Internal.evmBlockField) =>
  switch field {
  | Number | Timestamp | Hash | ParentHash | Nonce | Sha3Uncles
  | LogsBloom | TransactionsRoot | StateRoot | ReceiptsRoot | Miner
  | Difficulty | TotalDifficulty | ExtraData | Size | GasLimit | GasUsed
  | Uncles | BaseFeePerGas | BlobGasUsed | ExcessBlobGas
  | ParentBeaconBlockRoot | WithdrawalsRoot | L1BlockNumber | SendCount
  | SendRoot | MixHash => field
  }

let allEvmBlockFields = ([
  Number, Timestamp, Hash, ParentHash, Nonce, Sha3Uncles, LogsBloom,
  TransactionsRoot, StateRoot, ReceiptsRoot, Miner, Difficulty,
  TotalDifficulty, ExtraData, Size, GasLimit, GasUsed, Uncles,
  BaseFeePerGas, BlobGasUsed, ExcessBlobGas, ParentBeaconBlockRoot,
  WithdrawalsRoot, L1BlockNumber, SendCount, SendRoot, MixHash,
]: array<Internal.evmBlockField>)

// Exhaustiveness check: if a new variant is added to evmTransactionField,
// this match will fail to compile until it's added here and to the schema.
let checkTransactionField = (field: Internal.evmTransactionField) =>
  switch field {
  | TransactionIndex | Hash | From | To | Gas | GasPrice
  | MaxPriorityFeePerGas | MaxFeePerGas | CumulativeGasUsed
  | EffectiveGasPrice | GasUsed | Input | Nonce | Value | V | R | S
  | ContractAddress | LogsBloom | Root | Status | YParity | AccessList
  | MaxFeePerBlobGas | BlobVersionedHashes | Type | L1Fee | L1GasPrice
  | L1GasUsed | L1FeeScalar | GasUsedForL1 | AuthorizationList => field
  }

let allEvmTransactionFields = ([
  TransactionIndex, Hash, From, To, Gas, GasPrice, MaxPriorityFeePerGas,
  MaxFeePerGas, CumulativeGasUsed, EffectiveGasPrice, GasUsed, Input,
  Nonce, Value, V, R, S, ContractAddress, LogsBloom, Root, Status,
  YParity, AccessList, MaxFeePerBlobGas, BlobVersionedHashes, Type,
  L1Fee, L1GasPrice, L1GasUsed, L1FeeScalar, GasUsedForL1,
  AuthorizationList,
]: array<Internal.evmTransactionField>)

describe("Field selection enum schemas", () => {
  it("evmBlockFieldSchema parses all block field variants", t => {
    allEvmBlockFields->Js.Array2.forEach(field => {
      // checkBlockField ensures exhaustiveness at compile time
      let field = checkBlockField(field)
      let json = (field :> string)->Js.Json.string
      t.expect(json->S.parseOrThrow(Internal.evmBlockFieldSchema)).toBe(field)
    })
  })

  it("evmTransactionFieldSchema parses all transaction field variants", t => {
    allEvmTransactionFields->Js.Array2.forEach(field => {
      // checkTransactionField ensures exhaustiveness at compile time
      let field = checkTransactionField(field)
      let json = (field :> string)->Js.Json.string
      t.expect(json->S.parseOrThrow(Internal.evmTransactionFieldSchema)).toBe(field)
    })
  })
})

describe("Config.fromPublic", () => {
  it("resolves ABI for lowercase contract name in internal config", t => {
    // Internal config JSON with a lowercase contract name key ("greeter")
    let publicConfigJson: Js.Json.t = %raw(`{
      "version": "0.0.1-dev",
      "name": "test",
      "evm": {
        "chains": {
          "ethereumMainnet": {
            "id": 1,
            "startBlock": 0,
            "rpcs": [{ "url": "https://eth.com", "for": "sync" }]
          }
        },
        "contracts": {
          "greeter": {
            "abi": [{"type":"event","name":"NewGreeting","inputs":[],"anonymous":false}],
            "events": [{ "event": "NewGreeting()", "name": "NewGreeting" }]
          }
        },
        "addressFormat": "checksum"
      }
    }`)

    // Generated.res would use the capitalized name "Greeter"
    let codegenChains: array<Config.codegenChain> = [
      {
        id: 1,
        contracts: [
          {
            Config.name: "Greeter",
            addresses: ["0x0000000000000000000000000000000000000001"],
            events: [],
            startBlock: None,
          },
        ],
      },
    ]

    // This should not throw - the fix capitalizes the internal config key
    // before lookup, so "greeter" -> "Greeter" matches the codegen name
    let config = Config.fromPublic(publicConfigJson, ~codegenChains)

    let chain = config.chainMap->ChainMap.values->Js.Array2.unsafe_get(0)
    let contracts = chain.contracts
    t.expect(contracts->Array.length, ~message="Should have one contract").toBe(1)
    let contract = contracts->Js.Array2.unsafe_get(0)
    t.expect(
      contract.name,
      ~message="Contract name should be the capitalized version from codegen",
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
            "rpcs": [{ "url": "https://eth.com", "for": "sync" }]
          }
        },
        "contracts": {
          "Greeter": {
            "abi": [{"type":"event","name":"NewGreeting","inputs":[],"anonymous":false}],
            "events": [{ "event": "NewGreeting()", "name": "NewGreeting" }]
          }
        },
        "addressFormat": "checksum"
      }
    }`)

    let codegenChains: array<Config.codegenChain> = [
      {
        id: 1,
        contracts: [
          {
            Config.name: "Greeter",
            addresses: ["0x0000000000000000000000000000000000000001"],
            events: [],
            startBlock: None,
          },
        ],
      },
    ]

    let config = Config.fromPublic(publicConfigJson, ~codegenChains)

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
