open Vitest
open Internal

let testApiToken =
  Env.envioApiToken->Option.getOrThrow(
    ~message="ENVIO_API_TOKEN env var must be set to run RpcSource tests",
  )

let mockLog = (
  ~transactionHash="0xabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdef",
): Rpc.GetLogs.log => {
  blockNumber: 123456,
  blockHash: "0xabcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
  address: Address.Evm.fromStringOrThrow("0x1234567890abcdef1234567890abcdef12345678"),
  topics: [
    "0xd78ad95fa46c994b6551d0da85fc275fe613dbe680204dd5837f03aa2f863b9b",
    "0x0000000000000000000000000000000000000000000000000000000000000000",
  ],
  transactionHash,
  transactionIndex: 1,
  logIndex: 2,
}

describe("RpcSource - name", () => {
  it("Returns the name of the source including sanitized rpc url", t => {
    let source = RpcSource.make({
      url: "https://eth.rpc.hypersync.xyz?api_key=123",
      chain: MockConfig.chain1337,
      eventRouter: EventRouter.empty(),
      sourceFor: Sync,
      syncConfig: EvmChain.getSyncConfig({}),
      allEventParams: [],
      lowercaseAddresses: false,
    })
    t.expect(source.name).toBe("RPC (eth.rpc.hypersync.xyz)")
  })
})

describe("RpcSource - getHeightOrThrow", () => {
  Async.it("Returns the current height of the chain", async t => {
    let source = RpcSource.make({
      url: `https://eth.rpc.hypersync.xyz/${testApiToken}`,
      chain: MockConfig.chain1337,
      eventRouter: EventRouter.empty(),
      sourceFor: Sync,
      syncConfig: EvmChain.getSyncConfig({}),
      allEventParams: [],
      lowercaseAddresses: false,
    })
    let height = await source.getHeightOrThrow()
    t.expect({
      "aboveLowerBound": height > 21994218,
      "belowUpperBound": height < 30000000,
    }).toEqual({
      "aboveLowerBound": true,
      "belowUpperBound": true,
    })
  })
})

describe("RpcSource - getEventTransactionOrThrow", () => {
  let neverGetTransactionJson = _ =>
    JsError.throwWithMessage("getTransactionJson should not be called")
  let neverGetReceiptJson = _ => JsError.throwWithMessage("getReceiptJson should not be called")

  Async.it(
    "Returns empty object when empty field selection. Doesn't make a transaction request",
    async t => {
      let getEventTransactionOrThrow = RpcSource.makeThrowingGetEventTransaction(
        ~getTransactionJson=neverGetTransactionJson,
        ~getReceiptJson=neverGetReceiptJson,
        ~lowercaseAddresses=false,
      )
      t.expect(
        await mockLog()->getEventTransactionOrThrow(
          ~selectedTransactionFields=Utils.Set.fromArray([]),
        ),
      ).toEqual(%raw(`{}`))
    },
  )

  Async.it("Works with a single transactionIndex field", async t => {
    let getEventTransactionOrThrow = RpcSource.makeThrowingGetEventTransaction(
      ~getTransactionJson=neverGetTransactionJson,
      ~getReceiptJson=neverGetReceiptJson,
      ~lowercaseAddresses=false,
    )
    t.expect(
      await mockLog()->getEventTransactionOrThrow(
        ~selectedTransactionFields=Utils.Set.fromArray([
          (TransactionIndex: Internal.evmTransactionField),
        ]),
      ),
    ).toEqual({
      "transactionIndex": 1,
    })
  })

  Async.it("Works with a single hash field", async t => {
    let getEventTransactionOrThrow = RpcSource.makeThrowingGetEventTransaction(
      ~getTransactionJson=neverGetTransactionJson,
      ~getReceiptJson=neverGetReceiptJson,
      ~lowercaseAddresses=false,
    )
    t.expect(
      await mockLog()->getEventTransactionOrThrow(
        ~selectedTransactionFields=Utils.Set.fromArray([Hash]),
      ),
    ).toEqual({
      "hash": "0xabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdef",
    })
  })

  Async.it("Works with a only transactionIndex & hash field", async t => {
    let getEventTransactionOrThrow = RpcSource.makeThrowingGetEventTransaction(
      ~getTransactionJson=neverGetTransactionJson,
      ~getReceiptJson=neverGetReceiptJson,
      ~lowercaseAddresses=false,
    )
    t.expect(
      await mockLog()->getEventTransactionOrThrow(
        ~selectedTransactionFields=Utils.Set.fromArray([
          Hash,
          (TransactionIndex: Internal.evmTransactionField),
        ]),
      ),
    ).toEqual({
      "hash": "0xabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdef",
      "transactionIndex": 1,
    })

    // In different fields order
    let getEventTransactionOrThrow = RpcSource.makeThrowingGetEventTransaction(
      ~getTransactionJson=neverGetTransactionJson,
      ~getReceiptJson=neverGetReceiptJson,
      ~lowercaseAddresses=false,
    )
    t.expect(
      await mockLog()->getEventTransactionOrThrow(
        ~selectedTransactionFields=Utils.Set.fromArray([
          (TransactionIndex: Internal.evmTransactionField),
          Hash,
        ]),
      ),
    ).toEqual({
      "hash": "0xabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdef",
      "transactionIndex": 1,
    })
  })

  Async.it("Queries transaction fields from raw JSON (with real RPC)", async t => {
    let testTransactionHash = "0x3dce529e9661cfb65defa88ae5cd46866ddf39c9751d89774d89728703c2049f"

    let rpcUrl = `https://eth.rpc.hypersync.xyz/${testApiToken}`
    let client = Rest.client(rpcUrl)

    let getEventTransactionOrThrow = RpcSource.makeThrowingGetEventTransaction(
      ~getTransactionJson=async txHash =>
        switch await Rpc.GetTransactionByHash.rawRoute->Rest.fetch(txHash, ~client) {
        | Some(json) => json
        | None => JsError.throwWithMessage(`Transaction not found for hash: ${txHash}`)
        },
      ~getReceiptJson=async txHash =>
        switch await Rpc.GetTransactionReceipt.rawRoute->Rest.fetch(txHash, ~client) {
        | Some(json) => json
        | None => JsError.throwWithMessage(`Receipt not found for hash: ${txHash}`)
        },
      ~lowercaseAddresses=false,
    )
    t.expect(
      await mockLog(~transactionHash=testTransactionHash)->getEventTransactionOrThrow(
        ~selectedTransactionFields=Utils.Set.fromArray([
          Hash,
          (TransactionIndex: Internal.evmTransactionField),
          From,
          To,
          Gas,
          GasPrice,
          MaxPriorityFeePerGas,
          MaxFeePerGas,
          Input,
          Nonce,
          Value,
          V,
          R,
          S,
          YParity,
          // Receipt fields
          GasUsed,
          EffectiveGasPrice,
          Status,
        ]),
      ),
    ).toEqual({
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
    })
    },
  )

  Async.itWithOptions(
    "Successfully fetches ZKSync EIP-712 transactions (type 0x71) with optional signature fields",
    {retry: 3},
    async t => {
      // Transaction from Abstract Testnet (ZKSync-based) that lacks r/s/v signature fields
      let testTransactionHash = "0x245134326b7fecdcb7e0ed0a6cf090fc8881a63420ecd329ef645686b85647ed"

      let client = Rest.client("https://api.testnet.abs.xyz")
      let getEventTransactionOrThrow = RpcSource.makeThrowingGetEventTransaction(
        ~getTransactionJson=async txHash =>
          switch await Rpc.GetTransactionByHash.rawRoute->Rest.fetch(txHash, ~client) {
          | Some(json) => json
          | None => JsError.throwWithMessage(`Transaction not found for hash: ${txHash}`)
          },
        ~getReceiptJson=neverGetReceiptJson,
        ~lowercaseAddresses=true,
      )

      // ZKSync EIP-712 transactions lack signature fields (v, r, s, yParity).
      // Per-field parsing handles this — absent fields are simply not included.
      t.expect(
        await mockLog(~transactionHash=testTransactionHash)->getEventTransactionOrThrow(
          ~selectedTransactionFields=Utils.Set.fromArray([
            Hash,
            From,
            To,
            Gas,
            GasPrice,
            Nonce,
            Value,
            Type,
            MaxFeePerGas,
            MaxPriorityFeePerGas,
          ]),
        ),
      ).toEqual({
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
      })
    },
  )

  // Issue #931: Contract creation transactions have null `to` field.
  // Per-field parsing handles this — null fields are simply not included in the result.
  Async.it(
    "Contract creation transaction with null `to` field should parse successfully",
    async t => {
      // Mock a contract creation tx where `to` is null
      let getEventTransactionOrThrow = RpcSource.makeThrowingGetEventTransaction(
        ~getTransactionJson=_ =>
          Promise.resolve(
            %raw(`{"from": "0x95222290DD7278Aa3Ddd389Cc1E1d165CC4BAfe5", "to": null, "gas": "0x5208"}`),
          ),
        ~getReceiptJson=neverGetReceiptJson,
        ~lowercaseAddresses=false,
      )

      t.expect(
        await mockLog()->getEventTransactionOrThrow(
          ~selectedTransactionFields=Utils.Set.fromArray([From, Gas]),
        ),
      ).toEqual({
        "from": "0x95222290DD7278Aa3Ddd389Cc1E1d165CC4BAfe5"->Address.Evm.fromStringOrThrow,
        "gas": 21000n,
      })
    },
  )

  // gasUsed, cumulativeGasUsed, and effectiveGasPrice are receipt-only fields.
  // Only the receipt JSON is fetched — transaction JSON is not needed.
  Async.it("Fetches gasUsed from receipt only (no transaction call)", async t => {
    let getEventTransactionOrThrow = RpcSource.makeThrowingGetEventTransaction(
      ~getTransactionJson=neverGetTransactionJson,
      ~getReceiptJson=_ => Promise.resolve(%raw(`{"gasUsed": "0x5208"}`)),
      ~lowercaseAddresses=false,
    )

    t.expect(
      await mockLog()->getEventTransactionOrThrow(
        ~selectedTransactionFields=Utils.Set.fromArray([GasUsed]),
      ),
    ).toEqual({"gasUsed": 21000n})
  })

  Async.it("Fetches cumulativeGasUsed from receipt only (no transaction call)", async t => {
    let getEventTransactionOrThrow = RpcSource.makeThrowingGetEventTransaction(
      ~getTransactionJson=neverGetTransactionJson,
      ~getReceiptJson=_ => Promise.resolve(%raw(`{"cumulativeGasUsed": "0x7a120"}`)),
      ~lowercaseAddresses=false,
    )

    t.expect(
      await mockLog()->getEventTransactionOrThrow(
        ~selectedTransactionFields=Utils.Set.fromArray([CumulativeGasUsed]),
      ),
    ).toEqual({"cumulativeGasUsed": 500000n})
  })

  Async.it("Fetches effectiveGasPrice from receipt only (no transaction call)", async t => {
    let getEventTransactionOrThrow = RpcSource.makeThrowingGetEventTransaction(
      ~getTransactionJson=neverGetTransactionJson,
      ~getReceiptJson=_ => Promise.resolve(%raw(`{"effectiveGasPrice": "0x41ef67ce5"}`)),
      ~lowercaseAddresses=false,
    )

    t.expect(
      await mockLog()->getEventTransactionOrThrow(
        ~selectedTransactionFields=Utils.Set.fromArray([EffectiveGasPrice]),
      ),
    ).toEqual({"effectiveGasPrice": 17699339493n})
  })

  Async.it(
    "Fetches from both transaction and receipt when fields from both are needed",
    async t => {
      let getEventTransactionOrThrow = RpcSource.makeThrowingGetEventTransaction(
        ~getTransactionJson=_ => Promise.resolve(%raw(`{"gas": "0x5208", "value": "0x3e8"}`)),
        ~getReceiptJson=_ =>
          Promise.resolve(
            %raw(`{"gasUsed": "0x5208", "effectiveGasPrice": "0x41ef67ce5", "status": "0x1"}`),
          ),
        ~lowercaseAddresses=false,
      )

      t.expect(
        await mockLog()->getEventTransactionOrThrow(
          ~selectedTransactionFields=Utils.Set.fromArray([
            Hash,
            Gas,
            GasUsed,
            EffectiveGasPrice,
            Status,
          ]),
        ),
      ).toEqual({
        "hash": "0xabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdef",
        "gas": 21000n,
        "gasUsed": 21000n,
        "effectiveGasPrice": 17699339493n,
        "status": 1,
      })
    },
  )

  Async.it("Transaction-only fields don't call getReceiptJson", async t => {
    let getEventTransactionOrThrow = RpcSource.makeThrowingGetEventTransaction(
      ~getTransactionJson=_ => Promise.resolve(%raw(`{"gas": "0x5208", "input": "0xdeadbeef"}`)),
      ~getReceiptJson=neverGetReceiptJson,
      ~lowercaseAddresses=false,
    )

    t.expect(
      await mockLog()->getEventTransactionOrThrow(
        ~selectedTransactionFields=Utils.Set.fromArray([Gas, Input]),
      ),
    ).toEqual({
      "gas": 21000n,
      "input": "0xdeadbeef",
    })
  })

  Async.it("Unknown extra fields in JSON don't cause failures", async t => {
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

    t.expect(
      await mockLog()->getEventTransactionOrThrow(
        ~selectedTransactionFields=Utils.Set.fromArray([Gas]),
      ),
    ).toEqual({"gas": 21000n})
  })

  Async.it("Fetches l1FeeScalar from receipt (decimal string, not hex)", async t => {
    let getEventTransactionOrThrow = RpcSource.makeThrowingGetEventTransaction(
      ~getTransactionJson=neverGetTransactionJson,
      ~getReceiptJson=_ => Promise.resolve(%raw(`{"l1FeeScalar": "0.684"}`)),
      ~lowercaseAddresses=false,
    )

    t.expect(
      await mockLog()->getEventTransactionOrThrow(
        ~selectedTransactionFields=Utils.Set.fromArray([L1FeeScalar]),
      ),
    ).toEqual({"l1FeeScalar": 0.684})
  })

  Async.it("Error with a value not matching the field schema", async t => {
    let getEventTransactionOrThrow = RpcSource.makeThrowingGetEventTransaction(
      ~getTransactionJson=_ => Promise.resolve(%raw(`{"gas": "not-a-hex-value"}`)),
      ~getReceiptJson=neverGetReceiptJson,
      ~lowercaseAddresses=false,
    )
    try {
      let _ = await mockLog()->getEventTransactionOrThrow(
        ~selectedTransactionFields=Utils.Set.fromArray([Gas]),
      )
      JsError.throwWithMessage("Should have thrown")
    } catch {
    | JsExn(e) =>
      t.expect(
        e->JsExn.message->Option.getOrThrow,
      ).toBe(`Invalid transaction field "gas" found in the RPC response. Error: The string is not valid hex`)
    }
  })

  Async.it("Address fields are normalized with lowercaseAddresses=true", async t => {
    let getEventTransactionOrThrow = RpcSource.makeThrowingGetEventTransaction(
      ~getTransactionJson=neverGetTransactionJson,
      ~getReceiptJson=_ =>
        Promise.resolve(
          %raw(`{"from": "0x95222290DD7278Aa3Ddd389Cc1E1d165CC4BAfe5", "contractAddress": "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"}`),
        ),
      ~lowercaseAddresses=true,
    )

    let result = await mockLog()->getEventTransactionOrThrow(
      ~selectedTransactionFields=Utils.Set.fromArray([From, ContractAddress]),
    )
    t.expect(result).toEqual({
      "from": "0x95222290dd7278aa3ddd389cc1e1d165cc4bafe5"->Address.unsafeFromString,
      "contractAddress": "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48"->Address.unsafeFromString,
    })
  })
})

describe("RpcSource - getEventBlockOrThrow", () => {
  let neverGetBlockJson = _ => JsError.throwWithMessage("getBlockJson should not be called")
  // Internal.eventBlock is opaque, cast to Js.Json.t for test assertions
  let toJson = (block: Internal.eventBlock) => block->(Utils.magic: Internal.eventBlock => JSON.t)

  Async.it(
    "Returns empty object when empty field selection. Doesn't make a block request",
    async t => {
      let getEventBlockOrThrow = RpcSource.makeThrowingGetEventBlock(
        ~getBlockJson=neverGetBlockJson,
        ~lowercaseAddresses=false,
      )
      t.expect(
        (
          await mockLog()->getEventBlockOrThrow(~selectedBlockFields=Utils.Set.fromArray([]))
        )->toJson,
      ).toEqual(%raw(`{}`))
    },
  )

  Async.it("Works with a single number field", async t => {
    let getEventBlockOrThrow = RpcSource.makeThrowingGetEventBlock(
      ~getBlockJson=_ =>
        Promise.resolve(%raw(`{"number": "0x1e240", "timestamp": "0x5f5e100", "hash": "0xabc"}`)),
      ~lowercaseAddresses=false,
    )
    t.expect(
      (
        await mockLog()->getEventBlockOrThrow(~selectedBlockFields=Utils.Set.fromArray([Number]))
      )->toJson,
    ).toEqual(%raw(`{"number": 123456}`))
  })

  Async.it("Works with number, timestamp, and hash fields", async t => {
    let getEventBlockOrThrow = RpcSource.makeThrowingGetEventBlock(
      ~getBlockJson=_ =>
        Promise.resolve(
          %raw(`{"number": "0x1e240", "timestamp": "0x5f5e100", "hash": "0xabcdef"}`),
        ),
      ~lowercaseAddresses=false,
    )
    t.expect(
      (
        await mockLog()->getEventBlockOrThrow(
          ~selectedBlockFields=Utils.Set.fromArray([Number, Timestamp, (Hash: evmBlockField)]),
        )
      )->toJson,
    ).toEqual(%raw(`{"number": 123456, "timestamp": 100000000, "hash": "0xabcdef"}`))
  })

  Async.it("Parses selected block fields from raw JSON", async t => {
    let getEventBlockOrThrow = RpcSource.makeThrowingGetEventBlock(
      ~getBlockJson=_ =>
        Promise.resolve(
          %raw(`{
            "number": "0x1e240",
            "timestamp": "0x5f5e100",
            "hash": "0xabcdef",
            "gasUsed": "0x5208",
            "gasLimit": "0x1c9c380",
            "parentHash": "0xparent",
            "miner": "0x95222290DD7278Aa3Ddd389Cc1E1d165CC4BAfe5"
          }`),
        ),
      ~lowercaseAddresses=false,
    )
    t.expect(
      (
        await mockLog()->getEventBlockOrThrow(
          ~selectedBlockFields=Utils.Set.fromArray([(GasUsed: evmBlockField), GasLimit]),
        )
      )->toJson,
    ).toEqual(%raw(`{"gasUsed": 21000n, "gasLimit": 30000000n}`))
  })

  Async.it("Parses miner address with lowercaseAddresses=true", async t => {
    let getEventBlockOrThrow = RpcSource.makeThrowingGetEventBlock(
      ~getBlockJson=_ =>
        Promise.resolve(
          %raw(`{
            "number": "0x1",
            "timestamp": "0x1",
            "hash": "0x1",
            "miner": "0x95222290DD7278Aa3Ddd389Cc1E1d165CC4BAfe5"
          }`),
        ),
      ~lowercaseAddresses=true,
    )
    let result = await mockLog()->getEventBlockOrThrow(
      ~selectedBlockFields=Utils.Set.fromArray([Miner]),
    )
    t.expect(result->toJson).toEqual(
      %raw(`{"miner": "0x95222290dd7278aa3ddd389cc1e1d165cc4bafe5"}`),
    )
  })

  Async.it("Parses miner address with lowercaseAddresses=false (checksum)", async t => {
    let getEventBlockOrThrow = RpcSource.makeThrowingGetEventBlock(
      ~getBlockJson=_ =>
        Promise.resolve(
          %raw(`{
            "number": "0x1",
            "timestamp": "0x1",
            "hash": "0x1",
            "miner": "0x95222290DD7278Aa3Ddd389Cc1E1d165CC4BAfe5"
          }`),
        ),
      ~lowercaseAddresses=false,
    )
    let result = await mockLog()->getEventBlockOrThrow(
      ~selectedBlockFields=Utils.Set.fromArray([Miner]),
    )
    t.expect(result->toJson).toEqual(
      %raw(`{"miner": "0x95222290DD7278Aa3Ddd389Cc1E1d165CC4BAfe5"}`),
    )
  })

  Async.it("Unknown extra fields in JSON don't cause failures", async t => {
    let getEventBlockOrThrow = RpcSource.makeThrowingGetEventBlock(
      ~getBlockJson=_ =>
        Promise.resolve(
          %raw(`{
            "number": "0x1e240",
            "timestamp": "0x5f5e100",
            "hash": "0xabcdef",
            "gasUsed": "0x5208",
            "unknownField": "some value",
            "anotherUnknown": 42,
            "transactions": ["0x123"]
          }`),
        ),
      ~lowercaseAddresses=false,
    )
    t.expect(
      (
        await mockLog()->getEventBlockOrThrow(
          ~selectedBlockFields=Utils.Set.fromArray([(GasUsed: evmBlockField)]),
        )
      )->toJson,
    ).toEqual(%raw(`{"gasUsed": 21000n}`))
  })

  Async.it("Error with a value not matching the field schema", async t => {
    let getEventBlockOrThrow = RpcSource.makeThrowingGetEventBlock(
      ~getBlockJson=_ =>
        Promise.resolve(
          %raw(`{
            "number": "0x1",
            "timestamp": "0x1",
            "hash": "0x1",
            "gasUsed": "not-a-hex-value"
          }`),
        ),
      ~lowercaseAddresses=false,
    )
    try {
      let _ = await mockLog()->getEventBlockOrThrow(
        ~selectedBlockFields=Utils.Set.fromArray([(GasUsed: evmBlockField)]),
      )
      JsError.throwWithMessage("Should have thrown")
    } catch {
    | JsExn(e) =>
      t.expect(
        e->JsExn.message->Option.getOrThrow,
      ).toBe(`Invalid block field "gasUsed" found in the RPC response. Error: The string is not valid hex`)
    }
  })

  Async.it("Parses optional fields correctly (nullable with value)", async t => {
    let getEventBlockOrThrow = RpcSource.makeThrowingGetEventBlock(
      ~getBlockJson=_ =>
        Promise.resolve(
          %raw(`{
            "number": "0x1",
            "timestamp": "0x1",
            "hash": "0x1",
            "baseFeePerGas": "0x3b9aca00",
            "difficulty": "0x400000000"
          }`),
        ),
      ~lowercaseAddresses=false,
    )
    let result =
      (
        await mockLog()->getEventBlockOrThrow(
          ~selectedBlockFields=Utils.Set.fromArray([BaseFeePerGas, Difficulty]),
        )
      )->toJson
    t.expect(result).toEqual(%raw(`{"baseFeePerGas": 1000000000n, "difficulty": 17179869184n}`))
  })

  Async.it("Queries block fields from raw JSON (with real RPC)", async t => {
    let rpcUrl = `https://eth.rpc.hypersync.xyz/${testApiToken}`
    let client = Rpc.makeClient(rpcUrl)

    let getEventBlockOrThrow = RpcSource.makeThrowingGetEventBlock(
      ~getBlockJson=async blockNumber =>
        switch await Rpc.getRawBlock(~client, ~blockNumber) {
        | Some(json) => json
        | None =>
          JsError.throwWithMessage(`Block not found for number: ${blockNumber->Int.toString}`)
        },
      ~lowercaseAddresses=false,
    )

    // Block 21758655 on Ethereum mainnet
    let log = {
      ...mockLog(),
      blockNumber: 21758655,
    }

    t.expect(
      (
        await log->getEventBlockOrThrow(
          ~selectedBlockFields=Utils.Set.fromArray([
            Number,
            Timestamp,
            (Hash: evmBlockField),
            GasUsed,
            GasLimit,
            BaseFeePerGas,
            ParentHash,
          ]),
        )
      )->toJson,
    ).toEqual(
      %raw(`{
        "number": 21758655,
        "timestamp": 1738497227,
        "hash": "0x806a18dd9f7bb88e35e08658783c556974ea46a222f1f85a0bccb1da31bbde5f",
        "gasUsed": 23618146n,
        "gasLimit": 30352977n,
        "baseFeePerGas": 3237306347n,
        "parentHash": "0x58ebb0c939bed8e69d7e3519f579b028338613050986d0a3e8770de2c7ec2949"
      }`),
    )
    },
  )
})

describe("RpcSource - fieldRegistry completeness", () => {
  it("blockFieldRegistry contains all evmBlockField variants", t => {
    let registry = RpcSource.blockFieldRegistryLowercase
    let missing =
      Internal.allEvmBlockFields->Array.filter(field => registry->Utils.Record.get(field) == None)
    t.expect(missing->(Utils.magic: array<evmBlockField> => array<string>)).toEqual([])
  })

  it("fieldRegistry contains all non-log-derived evmTransactionField variants", t => {
    let registry = RpcSource.fieldRegistryLowercase
    // TransactionIndex and Hash are log-derived, AccessList and AuthorizationList are not in the RPC registry
    let logDerivedOrUnsupported: array<evmTransactionField> = [
      TransactionIndex,
      Hash,
      AccessList,
      AuthorizationList,
    ]
    let missing =
      Internal.allEvmTransactionFields->Array.filter(
        field =>
          registry->Utils.Record.get(field) == None &&
            logDerivedOrUnsupported->Array.every(excluded => excluded != field),
      )
    t.expect(missing->(Utils.magic: array<evmTransactionField> => array<string>)).toEqual([])
  })
})

let chain = HyperSyncSource_test.chain
describe("RpcSource - getSelectionConfig", () => {
  let mockAddress0 = Envio.TestHelpers.Addresses.mockAddresses[0]->Option.getOrThrow

  it("Selection config for the most basic case with no wildcards", t => {
    let selectionConfig = {
      dependsOnAddresses: true,
      eventConfigs: [(MockIndexer.evmEventConfig() :> Internal.eventConfig)],
    }->RpcSource.getSelectionConfig(~chain)

    t.expect(
      selectionConfig.getLogSelectionsOrThrow(
        ~addressesByContractName=Dict.fromArray([("ERC20", [mockAddress0])]),
      ),
      ~message=`Should include only single topic0 address`,
    ).toEqual([
      {
        addresses: Some([mockAddress0]),
        topicQuery: [Single(MockIndexer.eventId)],
      },
    ])
  })

  it("Selection config with wildcard events", t => {
    let selectionConfig = {
      dependsOnAddresses: false,
      eventConfigs: [
        (MockIndexer.evmEventConfig(~id="1", ~isWildcard=true) :> Internal.eventConfig),
        (MockIndexer.evmEventConfig(~id="2", ~isWildcard=true) :> Internal.eventConfig),
      ],
    }->RpcSource.getSelectionConfig(~chain)

    t.expect(
      selectionConfig.getLogSelectionsOrThrow(~addressesByContractName=Dict.make()),
      ~message=`Should compress filter-less wildcard events into one topic0 OR-set`,
    ).toEqual([
      {
        addresses: None,
        topicQuery: [Multiple(["1", "2"])],
      },
    ])
  })

  Async.it("Wildcard topic selection which depends on addresses", async t => {
    let selectionConfig = {
      dependsOnAddresses: false,
      eventConfigs: [
        (MockIndexer.evmEventConfig(
          ~id="event 2",
          ~isWildcard=true,
          ~dependsOnAddresses=true,
        ) :> Internal.eventConfig),
      ],
    }->RpcSource.getSelectionConfig(~chain)

    t.expect(
      selectionConfig.getLogSelectionsOrThrow(
        ~addressesByContractName=Dict.fromArray([("ERC20", [mockAddress0])]),
      ),
    ).toEqual([
      {
        addresses: None,
        topicQuery: [Single("event 2"), Single(mockAddress0->Address.toString)],
      },
    ])
  })

  Async.it("Non-wildcard topic selection which depends on addresses", async t => {
    let selectionConfig = {
      dependsOnAddresses: false,
      eventConfigs: [
        (MockIndexer.evmEventConfig(
          ~id="event 2",
          ~isWildcard=false,
          ~dependsOnAddresses=true,
        ) :> Internal.eventConfig),
      ],
    }->RpcSource.getSelectionConfig(~chain)

    t.expect(
      selectionConfig.getLogSelectionsOrThrow(
        ~addressesByContractName=Dict.fromArray([("ERC20", [mockAddress0])]),
      ),
    ).toEqual([
      {
        addresses: Some([mockAddress0]),
        topicQuery: [Single("event 2"), Single(mockAddress0->Address.toString)],
      },
    ])
  })

  it("Fans out one selection per wildcard event that has filters", t => {
    let selectionConfig = {
      dependsOnAddresses: false,
      eventConfigs: [
        (MockIndexer.evmEventConfig(
          ~id="1",
          ~isWildcard=true,
          ~eventFilters=Static([
            {
              topic0: ["1"->EvmTypes.Hex.fromStringUnsafe],
              topic1: ["a"->EvmTypes.Hex.fromStringUnsafe],
              topic2: [],
              topic3: [],
            },
          ]),
        ) :> Internal.eventConfig),
        (MockIndexer.evmEventConfig(
          ~id="2",
          ~isWildcard=true,
          ~eventFilters=Static([
            {
              topic0: ["2"->EvmTypes.Hex.fromStringUnsafe],
              topic1: ["b"->EvmTypes.Hex.fromStringUnsafe],
              topic2: [],
              topic3: [],
            },
          ]),
        ) :> Internal.eventConfig),
      ],
    }->RpcSource.getSelectionConfig(~chain)

    t.expect(
      selectionConfig.getLogSelectionsOrThrow(~addressesByContractName=Dict.make()),
    ).toEqual([
      {
        addresses: None,
        topicQuery: [Single("1"), Single("a")],
      },
      {
        addresses: None,
        topicQuery: [Single("2"), Single("b")],
      },
    ])
  })

  it("Fans out one selection per group of a single wildcard event's OR filter", t => {
    let selectionConfig = {
      dependsOnAddresses: false,
      eventConfigs: [
        (MockIndexer.evmEventConfig(
          ~id="w",
          ~isWildcard=true,
          ~eventFilters=Static([
            {
              topic0: ["w"->EvmTypes.Hex.fromStringUnsafe],
              topic1: ["a"->EvmTypes.Hex.fromStringUnsafe],
              topic2: [],
              topic3: [],
            },
            {
              topic0: ["w"->EvmTypes.Hex.fromStringUnsafe],
              topic1: [],
              topic2: ["b"->EvmTypes.Hex.fromStringUnsafe],
              topic3: [],
            },
          ]),
        ) :> Internal.eventConfig),
      ],
    }->RpcSource.getSelectionConfig(~chain)

    t.expect(
      selectionConfig.getLogSelectionsOrThrow(~addressesByContractName=Dict.make()),
    ).toEqual([
      {
        addresses: None,
        topicQuery: [Single("w"), Single("a")],
      },
      {
        addresses: None,
        topicQuery: [Single("w"), Null, Single("b")],
      },
    ])
  })

  it("Panics when selection has empty event configs", t => {
    try {
      let _ = {
        dependsOnAddresses: true,
        eventConfigs: [],
      }->RpcSource.getSelectionConfig(~chain)
      JsError.throwWithMessage("Should have thrown")
    } catch {
    | Source.GetItemsError(UnsupportedSelection({message})) =>
      t.expect(message).toBe(
        "Invalid events configuration for the partition. Nothing to fetch. Please, report to the Envio team.",
      )
    | _ => JsError.throwWithMessage("Should have thrown UnsupportedSelection")
    }
  })

  it("Fans out one selection per event when a normal event is mixed with a filtered event", t => {
    let selectionConfig = {
      dependsOnAddresses: true,
      eventConfigs: [
        (MockIndexer.evmEventConfig(~id="1") :> Internal.eventConfig),
        (MockIndexer.evmEventConfig(~id="2", ~dependsOnAddresses=true) :> Internal.eventConfig),
      ],
    }->RpcSource.getSelectionConfig(~chain)

    t.expect(
      selectionConfig.getLogSelectionsOrThrow(
        ~addressesByContractName=Dict.fromArray([("ERC20", [mockAddress0])]),
      ),
    ).toEqual([
      {
        addresses: Some([mockAddress0]),
        topicQuery: [Single("1")],
      },
      {
        addresses: Some([mockAddress0]),
        topicQuery: [Single("2"), Single(mockAddress0->Address.toString)],
      },
    ])
  })
})

describe("RpcSource - getSuggestedBlockIntervalFromExn", () => {
  let getSuggestedBlockIntervalFromExn = RpcSource.getSuggestedBlockIntervalFromExn

  it("Should handle retry with the range", t => {
    let error = JsExn(
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

    t.expect(getSuggestedBlockIntervalFromExn(error)).toEqual(Some((510, false)))
  })

  it("Shouldn't retry on height not available", t => {
    let error = JsExn(
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

    t.expect(getSuggestedBlockIntervalFromExn(error)).toEqual(None)
  })

  it("Should retry on block range too large", t => {
    let error = JsExn(
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

    t.expect(getSuggestedBlockIntervalFromExn(error)).toEqual(Some((1000, true)))
  })

  it("Should ignore invalid range errors where toBlock is less than fromBlock", t => {
    let error = JsExn(
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

    t.expect(getSuggestedBlockIntervalFromExn(error)).toEqual(None)
  })

  it("Should handle block range limit from https://1rpc.io/eth", t => {
    let error = JsExn(
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

    t.expect(getSuggestedBlockIntervalFromExn(error)).toEqual(Some((1000, true)))
  })

  it("Should handle block range limit from Alchemy", t => {
    let error = JsExn(
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

    t.expect(getSuggestedBlockIntervalFromExn(error)).toEqual(Some((500, true)))
  })

  it("Should handle Rpc.JsonRpcError with block range limit", t => {
    let error = Rpc.JsonRpcError({
      code: -32000,
      message: "eth_getLogs is limited to a 1000 blocks range",
    })
    t.expect(getSuggestedBlockIntervalFromExn(error)).toEqual(Some((1000, true)))
  })

  it("Should handle Rpc.JsonRpcError with suggested range", t => {
    let error = Rpc.JsonRpcError({
      code: -32602,
      message: "query exceeds max results 20000, retry with the range 6000000-6000509",
    })
    t.expect(getSuggestedBlockIntervalFromExn(error)).toEqual(Some((510, false)))
  })
})

describe("RpcSource - isResponseTooLargeError", () => {
  let isResponseTooLargeError = RpcSource.isResponseTooLargeError

  it("Classifies deterministic too-large responses and ignores unrelated errors", t => {
    let make = (code, message) => Rpc.JsonRpcError({code, message})
    t.expect({
      // HyperRPC 50k-log cap — the case the benchmark hits
      "hyperRpc": make(-32005, "More than 50000 logs returned")->isResponseTooLargeError,
      "zkEvm": make(-32000, "query returned more than 10000 results")->isResponseTooLargeError,
      "llamaRpc": make(-32000, "query exceeds max results")->isResponseTooLargeError,
      "optimism": make(-32000, "backend response too large")->isResponseTooLargeError,
      "arbitrum": make(
        -32000,
        "logs matched by query exceeds limit of 10000",
      )->isResponseTooLargeError,
      // Block-range limits are handled by getSuggestedBlockIntervalFromExn, not here
      "blockRangeLimit": make(
        -32005,
        "eth_getLogs is limited to a 1000 blocks range",
      )->isResponseTooLargeError,
      "rateLimit": make(-32029, "rate limited")->isResponseTooLargeError,
      "notJsonRpc": JsExn(%raw(`new Error("boom")`))->isResponseTooLargeError,
    }).toEqual({
      "hyperRpc": true,
      "zkEvm": true,
      "llamaRpc": true,
      "optimism": true,
      "arbitrum": true,
      "blockRangeLimit": false,
      "rateLimit": false,
      "notJsonRpc": false,
    })
  })
})

describe("RpcSource - getItemsOrThrow on response-too-large", () => {
  let sighash = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"
  let mockAddress = Envio.TestHelpers.Addresses.mockAddresses[0]->Option.getOrThrow

  Async.it(
    "Shrinks the partition block interval immediately (no backoff) on each too-large retry",
    async t => {
      let eventConfig = MockIndexer.evmEventConfig(~id=`${sighash}_1`)

      let blockJson = JSON.Object(
        Dict.fromArray([
          ("number", JSON.String("0x2710")),
          ("timestamp", JSON.String("0x64")),
          ("hash", JSON.String("0xb64")),
          ("parentHash", JSON.String("0xb63")),
        ]),
      )

      // eth_getLogs always trips the 50k-log cap; blocks resolve normally.
      let mock = await MockRpcServer.start(~handler=requestBody => {
        let method =
          requestBody
          ->JSON.parseOrThrow
          ->JSON.Decode.object
          ->Option.flatMap(Dict.get(_, "method"))
          ->Option.flatMap(JSON.Decode.string)
          ->Option.getOr("")
        switch method {
        | "eth_getLogs" => (
            200,
            `{"jsonrpc":"2.0","id":1,"error":{"code":-32005,"message":"More than 50000 logs returned"}}`,
          )
        | _ =>
          (
            200,
            JSON.stringify(
              JSON.Object(
                Dict.fromArray([
                  ("jsonrpc", JSON.String("2.0")),
                  ("id", JSON.Number(1.)),
                  ("result", blockJson),
                ]),
              ),
            ),
          )
        }
      })

      let source = RpcSource.make({
        url: mock.url,
        chain,
        eventRouter: [eventConfig]->EventRouter.fromEvmEventModsOrThrow(~chain),
        sourceFor: Sync,
        // initialBlockInterval=ceiling=10000, backoffMultiplicative=0.8
        syncConfig: EvmChain.getSyncConfig({}),
        allEventParams: [
          {
            sighash,
            topicCount: 1,
            eventName: eventConfig.name,
            contractName: eventConfig.contractName,
            params: [],
          },
        ],
        lowercaseAddresses: false,
      })

      let callGetItemsOrThrow = async (~toBlock) =>
        try {
          let _ = await source.getItemsOrThrow(
            ~fromBlock=0,
            ~toBlock,
            ~addressesByContractName=Dict.fromArray([(eventConfig.contractName, [mockAddress])]),
            ~contractNameByAddress=FetchState.deriveContractNameByAddress(
              Dict.fromArray([(eventConfig.contractName, [mockAddress])]),
            ),
            ~knownHeight=1_000_000,
            ~partitionId="0",
            ~selection={
              dependsOnAddresses: true,
              eventConfigs: [(eventConfig :> Internal.eventConfig)],
            },
            ~retry=0,
            ~logger=Logging.createChild(~params={"test": "RpcSource response too large"}),
          )
          None
        } catch {
        | Source.GetItemsError(error) => Some(error)
        }

      // Project away the live exn object (it carries a JS Error with a stack
      // that a literal can't match); assert the resize behavior instead.
      let summarize = opt =>
        switch opt {
        | Some(Source.FailedGettingItems({exn, attemptedToBlock, retry})) =>
          {
            "attemptedToBlock": attemptedToBlock,
            "retry": switch retry {
            | WithSuggestedToBlock({toBlock}) => `immediate-resize->${toBlock->Int.toString}`
            | WithBackoff({backoffMillis}) => `backoff-${backoffMillis->Int.toString}ms`
            | ImpossibleForTheQuery(_) => "impossible"
            },
            "errorMessage": exn->RpcSource.getErrorMessage,
          }->Some
        | _ => None
        }

      let caught = try {
        // First attempt uses initialBlockInterval (10000) → suggests 8000.
        // Second attempt uses the shrunk interval (8000) → suggests 6400.
        let first = await callGetItemsOrThrow(~toBlock=Some(1_000_000))
        let second = await callGetItemsOrThrow(~toBlock=Some(1_000_000))
        mock.close()
        (first->summarize, second->summarize)
      } catch {
      | exn =>
        mock.close()
        throw(exn)
      }

      t.expect(caught).toEqual((
        Some({
          "attemptedToBlock": 9999,
          "retry": "immediate-resize->7999",
          "errorMessage": Some("More than 50000 logs returned"),
        }),
        Some({
          "attemptedToBlock": 7999,
          "retry": "immediate-resize->6399",
          "errorMessage": Some("More than 50000 logs returned"),
        }),
      ))
    },
  )

  Async.it(
    "Re-grows the partition interval on the next successful query after a density shrink",
    async t => {
      let eventConfig = MockIndexer.evmEventConfig(~id=`${sighash}_2`)

      let blockJson = JSON.Object(
        Dict.fromArray([
          ("number", JSON.String("0x2710")),
          ("timestamp", JSON.String("0x64")),
          ("hash", JSON.String("0xb64")),
          ("parentHash", JSON.String("0xb63")),
        ]),
      )

      // Only the first eth_getLogs is too dense; the rest fit, so the interval
      // shrinks once then re-adapts upward via acceleration.
      let getLogsCount = ref(0)
      let mock = await MockRpcServer.start(~handler=requestBody => {
        let method =
          requestBody
          ->JSON.parseOrThrow
          ->JSON.Decode.object
          ->Option.flatMap(Dict.get(_, "method"))
          ->Option.flatMap(JSON.Decode.string)
          ->Option.getOr("")
        switch method {
        | "eth_getLogs" =>
          getLogsCount := getLogsCount.contents + 1
          getLogsCount.contents == 1
            ? (
                200,
                `{"jsonrpc":"2.0","id":1,"error":{"code":-32005,"message":"More than 50000 logs returned"}}`,
              )
            : (200, `{"jsonrpc":"2.0","id":1,"result":[]}`)
        | _ =>
          (
            200,
            JSON.stringify(
              JSON.Object(
                Dict.fromArray([
                  ("jsonrpc", JSON.String("2.0")),
                  ("id", JSON.Number(1.)),
                  ("result", blockJson),
                ]),
              ),
            ),
          )
        }
      })

      let source = RpcSource.make({
        url: mock.url,
        chain,
        eventRouter: [eventConfig]->EventRouter.fromEvmEventModsOrThrow(~chain),
        sourceFor: Sync,
        // initialBlockInterval=ceiling=10000, backoffMultiplicative=0.8, accelerationAdditive=500
        syncConfig: EvmChain.getSyncConfig({}),
        allEventParams: [
          {
            sighash,
            topicCount: 1,
            eventName: eventConfig.name,
            contractName: eventConfig.contractName,
            params: [],
          },
        ],
        lowercaseAddresses: false,
      })

      let call = async () =>
        try {
          let _ = await source.getItemsOrThrow(
            ~fromBlock=0,
            ~toBlock=Some(1_000_000),
            ~addressesByContractName=Dict.fromArray([(eventConfig.contractName, [mockAddress])]),
            ~contractNameByAddress=FetchState.deriveContractNameByAddress(
              Dict.fromArray([(eventConfig.contractName, [mockAddress])]),
            ),
            ~knownHeight=1_000_000,
            ~partitionId="0",
            ~selection={
              dependsOnAddresses: true,
              eventConfigs: [(eventConfig :> Internal.eventConfig)],
            },
            ~retry=0,
            ~logger=Logging.createChild(~params={"test": "RpcSource re-grow"}),
          )
          ()
        } catch {
        | Source.GetItemsError(_) => ()
        }

      let toBlockOfLogsRequest = body =>
        switch body->JSON.parseOrThrow->JSON.Decode.object {
        | Some(obj) if obj->Dict.get("method")->Option.flatMap(JSON.Decode.string) == Some("eth_getLogs") =>
          obj
          ->Dict.get("params")
          ->Option.flatMap(JSON.Decode.array)
          ->Option.flatMap(a => a->Array.get(0))
          ->Option.flatMap(JSON.Decode.object)
          ->Option.flatMap(p => p->Dict.get("toBlock"))
          ->Option.flatMap(JSON.Decode.string)
          ->Option.flatMap(hex => hex->String.slice(~start=2)->Int.fromString(~radix=16))
        | _ => None
        }

      let queriedToBlocks = try {
        // shrink 10000→8000 (fail), grow 8000→8500 (success), grow 8500→9000 (success)
        await call()
        await call()
        await call()
        let result = mock.requests->Array.filterMap(toBlockOfLogsRequest)
        mock.close()
        result
      } catch {
      | exn =>
        mock.close()
        throw(exn)
      }

      t.expect(queriedToBlocks).toEqual([9999, 7999, 8499])
    },
  )
})

describe("RpcSource - getItemsOrThrow with missing transaction data", () => {
  let sighash = "0xcf16a92280c1bbb43f72d31126b724d508df2877835849e8744017ab36a9b47f"
  let transactionHash = "0x27e26f21f744064a4af53810d8002bbd7208a2ca4865503a99b9c529e5cff5ea"
  let mockAddress = Envio.TestHelpers.Addresses.mockAddresses[0]->Option.getOrThrow

  // eth_getLogs runs through the Rust client's own HTTP stack, so a
  // globalThis.fetch stub can't intercept it; route every method through a
  // real local JSON-RPC server (MockRpcServer helper) instead.
  Async.it(
    "Throws a retryable error instead of a source-disabling one when the receipt is null",
    async t => {
      let eventConfig = MockIndexer.evmEventConfig(
        ~id=`${sighash}_1`,
        ~transactionFieldNames=[GasUsed],
      )

      let logJson = JSON.Object(
        Dict.fromArray([
          ("address", JSON.String(mockAddress->Address.toString)),
          ("topics", JSON.Array([JSON.String(sighash)])),
          ("data", JSON.String("0x")),
          ("blockNumber", JSON.String("0x64")),
          ("transactionHash", JSON.String(transactionHash)),
          ("transactionIndex", JSON.String("0x1")),
          ("blockHash", JSON.String("0xb64")),
          ("logIndex", JSON.String("0x2")),
          ("removed", JSON.Boolean(false)),
        ]),
      )
      let blockJson = JSON.Object(
        Dict.fromArray([
          ("number", JSON.String("0x64")),
          ("timestamp", JSON.String("0x64")),
          ("hash", JSON.String("0xb64")),
          ("parentHash", JSON.String("0xb63")),
        ]),
      )

      let mock = await MockRpcServer.make(~getResult=method =>
        switch method {
        | "eth_getLogs" => JSON.Array([logJson])
        | "eth_getBlockByNumber" => blockJson
        // eth_getTransactionByHash/eth_getTransactionReceipt return null,
        // like a load-balanced node that hasn't caught up with the head
        | _ => JSON.Null
        }
      )

      let source = RpcSource.make({
        url: mock.url,
        chain,
        eventRouter: [eventConfig]->EventRouter.fromEvmEventModsOrThrow(~chain),
        sourceFor: Sync,
        syncConfig: EvmChain.getSyncConfig({}),
        allEventParams: [
          {
            sighash,
            topicCount: 1,
            eventName: eventConfig.name,
            contractName: eventConfig.contractName,
            params: [],
          },
        ],
        lowercaseAddresses: false,
      })

      let caught = try {
        let callGetItemsOrThrow = async (~retry) =>
          try {
            let _ = await source.getItemsOrThrow(
              ~fromBlock=0,
              ~toBlock=Some(100),
              ~addressesByContractName=Dict.fromArray([(eventConfig.contractName, [mockAddress])]),
              ~contractNameByAddress=FetchState.deriveContractNameByAddress(
                Dict.fromArray([(eventConfig.contractName, [mockAddress])]),
              ),
              ~knownHeight=100,
              ~partitionId="0",
              ~selection={
                dependsOnAddresses: true,
                eventConfigs: [(eventConfig :> Internal.eventConfig)],
              },
              ~retry,
              ~logger=Logging.createChild(~params={"test": "RpcSource missing transaction data"}),
            )
            None
          } catch {
          | Source.GetItemsError(error) => Some(error)
          }
        let result = (await callGetItemsOrThrow(~retry=0), await callGetItemsOrThrow(~retry=2))
        mock.close()
        result
      } catch {
      | exn =>
        mock.close()
        throw(exn)
      }

      t.expect(caught).toEqual((
        Some(
          FailedGettingItems({
            exn: %raw(`null`),
            attemptedToBlock: 100,
            retry: WithBackoff({
              message: `Transaction receipt not found for hash: ${transactionHash}. The RPC provider might be load-balanced between nodes that drift independently slightly from the head. Indexing should continue correctly after retrying the query in 100ms.`,
              backoffMillis: 100,
            }),
          }),
        ),
        Some(
          FailedGettingItems({
            exn: %raw(`null`),
            attemptedToBlock: 100,
            retry: WithBackoff({
              message: `Transaction receipt not found for hash: ${transactionHash}. The RPC provider might be load-balanced between nodes that drift independently slightly from the head. Indexing should continue correctly after retrying the query in 1000ms.`,
              backoffMillis: 1000,
            }),
          }),
        ),
      ))
    },
  )
})

describe("RpcSource - getItemsOrThrow fans out multiple selections", () => {
  let sighash = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"
  let mockAddress = Envio.TestHelpers.Addresses.mockAddresses[0]->Option.getOrThrow

  Async.it(
    "Issues one eth_getLogs per selection and dedups a log matched by more than one",
    async t => {
      // A single event whose `where` is an OR of two param groups compiles to
      // two topic selections → two eth_getLogs. The mock returns the same log
      // for both, so the result must be deduped to one item.
      let eventConfig = MockIndexer.evmEventConfig(
        // `id` must equal the router key derived at lookup — `sighash_topicCount`
        ~id=`${sighash}_1`,
        ~eventFilters=Static([
          {
            topic0: [sighash->EvmTypes.Hex.fromStringUnsafe],
            topic1: [
              "0x0000000000000000000000000000000000000000000000000000000000000001"->EvmTypes.Hex.fromStringUnsafe,
            ],
            topic2: [],
            topic3: [],
          },
          {
            topic0: [sighash->EvmTypes.Hex.fromStringUnsafe],
            topic1: [],
            topic2: [
              "0x0000000000000000000000000000000000000000000000000000000000000002"->EvmTypes.Hex.fromStringUnsafe,
            ],
            topic3: [],
          },
        ]),
      )

      let logJson = JSON.Object(
        Dict.fromArray([
          ("address", JSON.String(mockAddress->Address.toString)),
          ("topics", JSON.Array([JSON.String(sighash)])),
          ("data", JSON.String("0x")),
          ("blockNumber", JSON.String("0x64")),
          (
            "transactionHash",
            JSON.String("0x27e26f21f744064a4af53810d8002bbd7208a2ca4865503a99b9c529e5cff5ea"),
          ),
          ("transactionIndex", JSON.String("0x1")),
          ("blockHash", JSON.String("0xb64")),
          ("logIndex", JSON.String("0x2")),
          ("removed", JSON.Boolean(false)),
        ]),
      )
      let blockJson = JSON.Object(
        Dict.fromArray([
          ("number", JSON.String("0x64")),
          ("timestamp", JSON.String("0x64")),
          ("hash", JSON.String("0xb64")),
          ("parentHash", JSON.String("0xb63")),
        ]),
      )

      let mock = await MockRpcServer.make(~getResult=method =>
        switch method {
        | "eth_getLogs" => JSON.Array([logJson])
        | "eth_getBlockByNumber" => blockJson
        | _ => JSON.Null
        }
      )

      let source = RpcSource.make({
        url: mock.url,
        chain,
        eventRouter: [eventConfig]->EventRouter.fromEvmEventModsOrThrow(~chain),
        sourceFor: Sync,
        syncConfig: EvmChain.getSyncConfig({}),
        allEventParams: [
          {
            sighash,
            topicCount: 1,
            eventName: eventConfig.name,
            contractName: eventConfig.contractName,
            params: [],
          },
        ],
        lowercaseAddresses: false,
      })

      let result = try {
        let page = await source.getItemsOrThrow(
          ~fromBlock=0,
          ~toBlock=Some(100),
          ~addressesByContractName=Dict.fromArray([(eventConfig.contractName, [mockAddress])]),
          ~contractNameByAddress=FetchState.deriveContractNameByAddress(
            Dict.fromArray([(eventConfig.contractName, [mockAddress])]),
          ),
          ~knownHeight=100,
          ~partitionId="0",
          ~selection={
            dependsOnAddresses: true,
            eventConfigs: [(eventConfig :> Internal.eventConfig)],
          },
          ~retry=0,
          ~logger=Logging.createChild(~params={"test": "RpcSource fan-out"}),
        )
        mock.close()
        page
      } catch {
      | exn =>
        mock.close()
        throw(exn)
      }

      let getLogsRequestCount =
        mock.requests->Array.filter(body => body->String.includes("eth_getLogs"))->Array.length

      t.expect((getLogsRequestCount, result.parsedQueueItems->Array.length)).toEqual((2, 1))
    },
  )
})

describe("RpcSource - getItemsOrThrow with a skip-all event filter", () => {
  let sighash = "0x8c5be1e5ebec7d5bd14f71427d1e84f3dd0314c0f7b2291e5b200ac8c7c3b925"

  Async.it(
    "Advances the range without an eth_getLogs when the filter resolves to no selections",
    async t => {
      // `where: false` compiles to an empty topic-selection set, so there is
      // nothing to query — the batch must advance the cursor without issuing an
      // eth_getLogs (and without throwing, which the pre-fan-out code did).
      let eventConfig = MockIndexer.evmEventConfig(
        ~id=`${sighash}_1`,
        ~isWildcard=true,
        ~eventFilters=Static([]),
      )

      // Echo the requested block number so `latestFetchedBlockNumber` reflects
      // the block the source actually loaded, not a constant baked into the mock.
      let mock = await MockRpcServer.makeWithParams(~getResult=(~method, ~params) =>
        switch method {
        | "eth_getBlockByNumber" =>
          let requestedBlockHex = switch params {
          | JSON.Array([JSON.String(hex), _]) => hex
          | _ => "0x0"
          }
          JSON.Object(
            Dict.fromArray([
              ("number", JSON.String(requestedBlockHex)),
              ("timestamp", JSON.String("0x64")),
              ("hash", JSON.String("0xb64")),
              ("parentHash", JSON.String("0xb63")),
            ]),
          )
        | _ => JSON.Null
        }
      )

      let source = RpcSource.make({
        url: mock.url,
        chain,
        eventRouter: [eventConfig]->EventRouter.fromEvmEventModsOrThrow(~chain),
        sourceFor: Sync,
        syncConfig: EvmChain.getSyncConfig({}),
        allEventParams: [
          {
            sighash,
            topicCount: 1,
            eventName: eventConfig.name,
            contractName: eventConfig.contractName,
            params: [],
          },
        ],
        lowercaseAddresses: false,
      })

      let result = try {
        let page = await source.getItemsOrThrow(
          ~fromBlock=0,
          ~toBlock=Some(100),
          ~addressesByContractName=Dict.make(),
          ~contractNameByAddress=FetchState.deriveContractNameByAddress(Dict.make()),
          ~knownHeight=100,
          ~partitionId="0",
          ~selection={
            dependsOnAddresses: false,
            eventConfigs: [(eventConfig :> Internal.eventConfig)],
          },
          ~retry=0,
          ~logger=Logging.createChild(~params={"test": "RpcSource skip-all"}),
        )
        mock.close()
        page
      } catch {
      | exn =>
        mock.close()
        throw(exn)
      }

      let getLogsRequestCount =
        mock.requests->Array.filter(body => body->String.includes("eth_getLogs"))->Array.length

      t.expect((
        getLogsRequestCount,
        result.parsedQueueItems->Array.length,
        result.latestFetchedBlockNumber,
      )).toEqual((0, 0, 100))
    },
  )
})
