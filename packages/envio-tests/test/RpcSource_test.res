open Vitest
open Internal

let testApiToken =
  Env.envioApiToken->Option.getOrThrow(
    ~message="ENVIO_API_TOKEN env var must be set to run RpcSource tests",
  )

describe("RpcSource - name", () => {
  it("Returns the name of the source including sanitized rpc url", t => {
    let source = RpcSource.make({
      url: "https://eth.rpc.hypersync.xyz?api_key=123",
      chainId: 1337->ChainId.fromInt,
      onEventRegistrations: [],
      sourceFor: Sync,
      syncConfig: EvmChain.getSyncConfig({}),
      lowercaseAddresses: false,
      addressStore: TestAddresses.makeStore(),
    })
    t.expect(source.name).toBe("RPC (eth.rpc.hypersync.xyz)")
  })
})

describe("RpcSource - getHeightOrThrow", () => {
  Async.itWithOptions("Returns the current height of the chain", {retry: 3}, async t => {
    let source = RpcSource.make({
      url: `https://eth.rpc.hypersync.xyz/${testApiToken}`,
      chainId: 1337->ChainId.fromInt,
      onEventRegistrations: [],
      sourceFor: Sync,
      syncConfig: EvmChain.getSyncConfig({}),
      lowercaseAddresses: false,
      addressStore: TestAddresses.makeStore(),
    })
    let {height} = await source.getHeightOrThrow()
    t.expect({
      "aboveLowerBound": height > 21994218,
      "belowUpperBound": height < 30000000,
    }).toEqual({
      "aboveLowerBound": true,
      "belowUpperBound": true,
    })
  })
})

// One store per test scope: the chain's registrations plus the emitters its
// crafted logs come from.
let makeAddressStore = (
  ~onEventRegistrations: array<Internal.evmOnEventRegistration>,
  ~addresses=[],
) =>
  TestAddresses.makeStore(
    ~onEventRegistrations=onEventRegistrations->Array.map(reg =>
      (reg :> Internal.onEventRegistration)
    ),
    ~addresses,
  )

let chainId = 1->ChainId.fromInt
describe("RpcSource - empty selection", () => {
  Async.it("Throws UnsupportedSelection when the selection has no event configs", async t => {
    let source = RpcSource.make({
      url: "http://localhost:1",
      chainId,
      onEventRegistrations: [],
      sourceFor: Sync,
      syncConfig: EvmChain.getSyncConfig({}),
      lowercaseAddresses: false,
      addressStore: TestAddresses.makeStore(),
    })

    let caught = try {
      let _ = await source.getItemsOrThrow(
        ~fromBlock=0,
        ~toBlock=Some(1),
        ~addressSet=TestAddresses.makeStore()->AddressStore.emptySet,
        ~knownHeight=1,
        ~partitionId="0",
        ~selection={dependsOnAddresses: true, onEventRegistrations: []},
        ~itemsTarget=Some(5000),
        ~retry=0,
        ~logger=Logging.createChild(~params={"test": "RpcSource empty selection"}),
      )
      None
    } catch {
    | Source.GetItemsError(UnsupportedSelection({message})) => Some(message)
    }

    t.expect(caught).toEqual(
      Some(
        "Invalid events configuration for the partition. Nothing to fetch. Please, report to the Envio team.",
      ),
    )
  })
})

describe("RpcSource - getItemsOrThrow on response-too-large", () => {
  let sighash = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"
  let mockAddress = Envio.TestHelpers.Addresses.mockAddresses[0]->Option.getOrThrow

  Async.it(
    "Shrinks the partition block interval immediately (no backoff) on each too-large retry",
    async t => {
      let eventConfig = {...EventRegistration.evmOnEventRegistration(~id=sighash), index: 0}

      let blockJson = JSON.Object(
        Dict.fromArray([
          ("number", JSON.String("0x2710")),
          ("timestamp", JSON.String("0x64")),
          (
            "hash",
            JSON.String("0x0000000000000000000000000000000000000000000000000000000000000b64"),
          ),
          (
            "parentHash",
            JSON.String("0x0000000000000000000000000000000000000000000000000000000000000b63"),
          ),
        ]),
      )

      // eth_getLogs always trips the 50k-log cap; blocks resolve normally.
      let mock = await MockRpcServer.start(
        ~handler=requestBody => {
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
          | _ => (
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
        },
      )

      let addressStore = makeAddressStore(
        ~onEventRegistrations=[eventConfig],
        ~addresses=[
          {
            address: mockAddress,
            contractName: eventConfig.eventConfig.contractName,
            registrationBlock: -1,
          },
        ],
      )
      let source = RpcSource.make({
        url: mock.url,
        chainId,
        onEventRegistrations: [eventConfig],
        sourceFor: Sync,
        // initialBlockInterval=ceiling=10000, backoffMultiplicative=0.8
        syncConfig: EvmChain.getSyncConfig({}),
        lowercaseAddresses: false,
        addressStore,
      })

      let callGetItemsOrThrow = async (~toBlock) =>
        try {
          let _ = await source.getItemsOrThrow(
            ~fromBlock=0,
            ~toBlock,
            ~addressSet=addressStore->AddressStore.makeSet(
              ~contractName=eventConfig.eventConfig.contractName,
            ),
            ~knownHeight=1_000_000,
            ~partitionId="0",
            ~selection={
              dependsOnAddresses: true,
              onEventRegistrations: [(eventConfig :> Internal.onEventRegistration)],
            },
            ~itemsTarget=Some(5000),
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
      let eventConfig = {...EventRegistration.evmOnEventRegistration(~id=sighash), index: 0}

      let blockJson = JSON.Object(
        Dict.fromArray([
          ("number", JSON.String("0x2710")),
          ("timestamp", JSON.String("0x64")),
          (
            "hash",
            JSON.String("0x0000000000000000000000000000000000000000000000000000000000000b64"),
          ),
          (
            "parentHash",
            JSON.String("0x0000000000000000000000000000000000000000000000000000000000000b63"),
          ),
        ]),
      )

      // Only the first eth_getLogs is too dense; the rest fit, so the interval
      // shrinks once then re-adapts upward via acceleration.
      let getLogsCount = ref(0)
      let mock = await MockRpcServer.start(
        ~handler=requestBody => {
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
          | _ => (
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
        },
      )

      let addressStore = makeAddressStore(
        ~onEventRegistrations=[eventConfig],
        ~addresses=[
          {
            address: mockAddress,
            contractName: eventConfig.eventConfig.contractName,
            registrationBlock: -1,
          },
        ],
      )
      let source = RpcSource.make({
        url: mock.url,
        chainId,
        onEventRegistrations: [eventConfig],
        sourceFor: Sync,
        // initialBlockInterval=ceiling=10000, backoffMultiplicative=0.8, accelerationAdditive=500
        syncConfig: EvmChain.getSyncConfig({}),
        lowercaseAddresses: false,
        addressStore,
      })

      let call = async () =>
        try {
          let _ = await source.getItemsOrThrow(
            ~fromBlock=0,
            ~toBlock=Some(1_000_000),
            ~addressSet=addressStore->AddressStore.makeSet(
              ~contractName=eventConfig.eventConfig.contractName,
            ),
            ~knownHeight=1_000_000,
            ~partitionId="0",
            ~selection={
              dependsOnAddresses: true,
              onEventRegistrations: [(eventConfig :> Internal.onEventRegistration)],
            },
            ~itemsTarget=Some(5000),
            ~retry=0,
            ~logger=Logging.createChild(~params={"test": "RpcSource re-grow"}),
          )
        } catch {
        | Source.GetItemsError(_) => ()
        }

      let toBlockOfLogsRequest = body =>
        switch body->JSON.parseOrThrow->JSON.Decode.object {
        | Some(obj)
          if obj->Dict.get("method")->Option.flatMap(JSON.Decode.string) == Some("eth_getLogs") =>
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

describe("RpcSource - getItemsOrThrow classifies real provider block-range errors", () => {
  let sighash = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"
  let mockAddress = Envio.TestHelpers.Addresses.mockAddresses[0]->Option.getOrThrow
  let eventConfig = {...EventRegistration.evmOnEventRegistration(~id=sighash), index: 0}

  let blockJson = JSON.Object(
    Dict.fromArray([
      ("number", JSON.String("0x2710")),
      ("timestamp", JSON.String("0x64")),
      ("hash", JSON.String("0x0000000000000000000000000000000000000000000000000000000000000b64")),
      (
        "parentHash",
        JSON.String("0x0000000000000000000000000000000000000000000000000000000000000b63"),
      ),
    ]),
  )

  let jsonRpcError = message =>
    JSON.stringify(
      JSON.Object(
        Dict.fromArray([
          ("jsonrpc", JSON.String("2.0")),
          ("id", JSON.Number(1.)),
          (
            "error",
            JSON.Object(
              Dict.fromArray([("code", JSON.Number(-32000.)), ("message", JSON.String(message))]),
            ),
          ),
        ]),
      ),
    )

  let jsonRpcResult = result =>
    JSON.stringify(
      JSON.Object(
        Dict.fromArray([
          ("jsonrpc", JSON.String("2.0")),
          ("id", JSON.Number(1.)),
          ("result", result),
        ]),
      ),
    )

  // Real `eth_getLogs` error messages providers return today (see the regex
  // comments in packages/cli/src/evm_rpc_source/classify.rs), fed through a
  // mock JSON-RPC server so each assertion exercises the actual napi boundary
  // instead of a hand-built exception.
  [
    (
      "an unknown provider's suggested range",
      "query exceeds max results 20000, retry with the range 6000000-6000509",
      510,
    ),
    (
      "evm-rpc.sei-apis.com's max-allowed-blocks",
      "block range too large (2000), maximum allowed is 1000 blocks",
      1000,
    ),
    ("1RPC's block range limit", "eth_getLogs is limited to a 1000 blocks range", 1000),
    (
      "Alchemy's block range",
      "You can make eth_getLogs requests with up to a 500 block range. Based on your parameters, this block range should work: [0x3d7773, 0x3d7966]",
      500,
    ),
    ("Cloudflare's max range", "Max range: 3500", 3500),
    ("Thirdweb's max requested blocks", "Maximum allowed number of requested blocks is 3500", 3500),
    ("BlockPI's limited-to range", "limited to 2000 block", 2000),
    ("Base's fixed range", "block range too large", 2000),
    ("Blast's paid-plan range", "exceeds the range allowed for your plan (5000 > 3000)", 3000),
    ("Chainstack's fixed range", "Block range limit exceeded.", 10000),
    ("Coinbase's at-most range", "please limit the query to at most 1000 blocks", 1000),
    ("PublicNode's max block range", "maximum block range: 2000", 2000),
    ("Hyperliquid's max block range", "query exceeds max block range 1000", 1000),
  ]->Array.forEach(((name, message, suggestedInterval)) => {
    Async.it(
      `Resizes to the suggested interval for ${name}`,
      async t => {
        let mock = await MockRpcServer.start(
          ~handler=requestBody => {
            let method =
              requestBody
              ->JSON.parseOrThrow
              ->JSON.Decode.object
              ->Option.flatMap(Dict.get(_, "method"))
              ->Option.flatMap(JSON.Decode.string)
              ->Option.getOr("")
            switch method {
            | "eth_getLogs" => (200, jsonRpcError(message))
            | _ => (200, jsonRpcResult(blockJson))
            }
          },
        )

        let addressStore = makeAddressStore(
          ~onEventRegistrations=[eventConfig],
          ~addresses=[
            {
              address: mockAddress,
              contractName: eventConfig.eventConfig.contractName,
              registrationBlock: -1,
            },
          ],
        )
        let source = RpcSource.make({
          url: mock.url,
          chainId,
          onEventRegistrations: [eventConfig],
          sourceFor: Sync,
          syncConfig: EvmChain.getSyncConfig({}),
          lowercaseAddresses: false,
          addressStore,
        })

        let retry = try {
          let result = try {
            let _ = await source.getItemsOrThrow(
              ~fromBlock=0,
              ~toBlock=Some(1_000_000),
              ~addressSet=addressStore->AddressStore.makeSet(
                ~contractName=eventConfig.eventConfig.contractName,
              ),
              ~knownHeight=1_000_000,
              ~partitionId="0",
              ~selection={
                dependsOnAddresses: true,
                onEventRegistrations: [(eventConfig :> Internal.onEventRegistration)],
              },
              ~itemsTarget=Some(5000),
              ~retry=0,
              ~logger=Logging.createChild(~params={"test": "RpcSource classify " ++ name}),
            )
            None
          } catch {
          | Source.GetItemsError(FailedGettingItems({retry})) => Some(retry)
          | Source.GetItemsError(_) => None
          }
          mock.close()
          result
        } catch {
        | exn =>
          mock.close()
          throw(exn)
        }

        t.expect(retry).toEqual(Some(WithSuggestedToBlock({toBlock: suggestedInterval - 1})))
      },
    )
  })
})

describe("RpcSource - getItemsOrThrow with missing transaction data", () => {
  let sighash = "0xcf16a92280c1bbb43f72d31126b724d508df2877835849e8744017ab36a9b47f"
  let transactionHash = "0x27e26f21f744064a4af53810d8002bbd7208a2ca4865503a99b9c529e5cff5ea"
  let mockAddress = Envio.TestHelpers.Addresses.mockAddresses[0]->Option.getOrThrow

  // eth_getLogs runs through the Rust client's own HTTP stack, so a
  // globalThis.fetch stub can't intercept it; route every method through a
  // real local JSON-RPC server (MockRpcServer helper) instead.
  Async.it(
    "Reports the missing receipt on the response, then fills it via a targeted refetch",
    async t => {
      let eventConfig = {
        ...EventRegistration.evmOnEventRegistration(~id=sighash, ~transactionFieldNames=[GasUsed]),
        index: 0,
      }

      let logJson = JSON.Object(
        Dict.fromArray([
          ("address", JSON.String(mockAddress->Address.toString)),
          ("topics", JSON.Array([JSON.String(sighash)])),
          ("data", JSON.String("0x")),
          ("blockNumber", JSON.String("0x64")),
          ("transactionHash", JSON.String(transactionHash)),
          ("transactionIndex", JSON.String("0x1")),
          (
            "blockHash",
            JSON.String("0x0000000000000000000000000000000000000000000000000000000000000b64"),
          ),
          ("logIndex", JSON.String("0x2")),
          ("removed", JSON.Boolean(false)),
        ]),
      )
      let blockJson = JSON.Object(
        Dict.fromArray([
          ("number", JSON.String("0x64")),
          ("timestamp", JSON.String("0x64")),
          (
            "hash",
            JSON.String("0x0000000000000000000000000000000000000000000000000000000000000b64"),
          ),
          (
            "parentHash",
            JSON.String("0x0000000000000000000000000000000000000000000000000000000000000b63"),
          ),
        ]),
      )

      // eth_getTransactionReceipt returns null at first, like a load-balanced
      // node that hasn't caught up with the one that served eth_getLogs; the
      // ref flips to a real receipt for the targeted refetch.
      let receiptResult = ref(JSON.Null)
      let mock = await MockRpcServer.make(
        ~getResult=method =>
          switch method {
          | "eth_getLogs" => JSON.Array([logJson])
          | "eth_getBlockByNumber" => blockJson
          | "eth_getTransactionReceipt" => receiptResult.contents
          | _ => JSON.Null
          },
      )

      let addressStore = makeAddressStore(
        ~onEventRegistrations=[eventConfig],
        ~addresses=[
          {
            address: mockAddress,
            contractName: eventConfig.eventConfig.contractName,
            registrationBlock: -1,
          },
        ],
      )
      let source = RpcSource.make({
        url: mock.url,
        chainId,
        onEventRegistrations: [eventConfig],
        sourceFor: Sync,
        syncConfig: EvmChain.getSyncConfig({}),
        lowercaseAddresses: false,
        addressStore,
      })

      let result = try {
        let response = await source.getItemsOrThrow(
          ~fromBlock=0,
          ~toBlock=Some(100),
          ~addressSet=addressStore->AddressStore.makeSet(
            ~contractName=eventConfig.eventConfig.contractName,
          ),
          ~knownHeight=100,
          ~partitionId="0",
          ~selection={
            dependsOnAddresses: true,
            onEventRegistrations: [(eventConfig :> Internal.onEventRegistration)],
          },
          ~itemsTarget=Some(5000),
          ~retry=0,
          ~logger=Logging.createChild(~params={"test": "RpcSource missing transaction data"}),
        )
        let missing = response.missingStoreData->Option.getOrThrow
        // The serving node caught up; SourceManager would now drive the
        // targeted refetch through the source's fetchItemsStoreData.
        receiptResult := JSON.Object(Dict.fromArray([("gasUsed", JSON.String("0x5208"))]))
        let fill = await (source.fetchItemsStoreData->Option.getOrThrow)(
          ~missing,
          ~transactionStore=response.transactionStore,
          ~blockStore=response.blockStore,
        )
        let materialized =
          await response.transactionStore
          ->Option.getOrThrow
          ->TransactionStore.materialize(
            ~blockNumbers=[100],
            ~transactionIndices=[1],
            ~masks=[Evm.eventTransactionFieldMask(Utils.Set.fromArray(["gasUsed"]))],
          )
        mock.close()
        (
          response.parsedQueueItems->Array.length,
          missing.transactions->Array.map(m => (m.blockNumber, m.transactionIndex)),
          missing.blocks,
          fill.stillMissing,
          materialized,
        )
      } catch {
      | exn =>
        mock.close()
        throw(exn)
      }

      t.expect(result).toEqual((
        1,
        [(100, 1)],
        [],
        None,
        [{"gasUsed": 21000n}->(Utils.magic: {..} => Internal.eventTransaction)],
      ))
    },
  )
})

describe("RpcSource - effectiveGasPrice fallback", () => {
  let sighash = "0xcf16a92280c1bbb43f72d31126b724d508df2877835849e8744017ab36a9b47f"
  let transactionHash = "0x27e26f21f744064a4af53810d8002bbd7208a2ca4865503a99b9c529e5cff5ea"
  let mockAddress = Envio.TestHelpers.Addresses.mockAddresses[0]->Option.getOrThrow

  let logJson = JSON.Object(
    Dict.fromArray([
      ("address", JSON.String(mockAddress->Address.toString)),
      ("topics", JSON.Array([JSON.String(sighash)])),
      ("data", JSON.String("0x")),
      ("blockNumber", JSON.String("0x64")),
      ("transactionHash", JSON.String(transactionHash)),
      ("transactionIndex", JSON.String("0x1")),
      (
        "blockHash",
        JSON.String("0x0000000000000000000000000000000000000000000000000000000000000b64"),
      ),
      ("logIndex", JSON.String("0x2")),
      ("removed", JSON.Boolean(false)),
    ]),
  )
  let blockJson = JSON.Object(
    Dict.fromArray([
      ("number", JSON.String("0x64")),
      ("timestamp", JSON.String("0x64")),
      ("hash", JSON.String("0x0000000000000000000000000000000000000000000000000000000000000b64")),
      (
        "parentHash",
        JSON.String("0x0000000000000000000000000000000000000000000000000000000000000b63"),
      ),
    ]),
  )

  let makeEgpSource = (~mock: MockRpcServer.t) => {
    let eventConfig = {
      ...EventRegistration.evmOnEventRegistration(
        ~id=sighash,
        ~transactionFieldNames=[EffectiveGasPrice],
      ),
      index: 0,
    }
    let addressStore = makeAddressStore(
      ~onEventRegistrations=[eventConfig],
      ~addresses=[
        {
          address: mockAddress,
          contractName: eventConfig.eventConfig.contractName,
          registrationBlock: -1,
        },
      ],
    )
    let source = RpcSource.make({
      url: mock.url,
      chainId,
      onEventRegistrations: [eventConfig],
      sourceFor: Sync,
      syncConfig: EvmChain.getSyncConfig({}),
      lowercaseAddresses: false,
      addressStore,
    })
    (source, eventConfig, addressStore)
  }

  let invoke = async (source: Source.t, ~eventConfig, ~addressStore) =>
    await source.getItemsOrThrow(
      ~fromBlock=0,
      ~toBlock=Some(100),
      ~addressSet=addressStore->AddressStore.makeSet(
        ~contractName=eventConfig.Internal.eventConfig.contractName,
      ),
      ~knownHeight=100,
      ~partitionId="0",
      ~selection={
        dependsOnAddresses: true,
        onEventRegistrations: [(eventConfig :> Internal.onEventRegistration)],
      },
      ~itemsTarget=Some(5000),
      ~retry=0,
      ~logger=Logging.createChild(~params={"test": "RpcSource effectiveGasPrice"}),
    )

  Async.it(
    "Falls back to the transaction's gasPrice when the receipt omits effectiveGasPrice",
    async t => {
      // Pre-EIP-1559 receipts (e.g. Optimism below the Bedrock migration)
      // carry no effectiveGasPrice; the transaction's gasPrice is the
      // effective price, fetched only when the receipt came back without it.
      let mock = await MockRpcServer.make(
        ~getResult=method =>
          switch method {
          | "eth_getLogs" => JSON.Array([logJson])
          | "eth_getBlockByNumber" => blockJson
          | "eth_getTransactionReceipt" =>
            JSON.Object(Dict.fromArray([("gasUsed", JSON.String("0x5208"))]))
          | "eth_getTransactionByHash" =>
            JSON.Object(Dict.fromArray([("gasPrice", JSON.String("0x3b9aca00"))]))
          | _ => JSON.Null
          },
      )
      let (source, eventConfig, addressStore) = makeEgpSource(~mock)

      let result = try {
        let response = await source->invoke(~eventConfig, ~addressStore)
        let materialized =
          await response.transactionStore
          ->Option.getOrThrow
          ->TransactionStore.materialize(
            ~blockNumbers=[100],
            ~transactionIndices=[1],
            ~masks=[Evm.eventTransactionFieldMask(Utils.Set.fromArray(["effectiveGasPrice"]))],
          )
        let transactionRequestCount =
          mock.requests
          ->Array.filter(body => body->String.includes("eth_getTransactionByHash"))
          ->Array.length
        mock.close()
        (response.missingStoreData, transactionRequestCount, materialized)
      } catch {
      | exn =>
        mock.close()
        throw(exn)
      }

      t.expect(result).toEqual((
        None,
        1,
        [{"effectiveGasPrice": 1000000000n}->(Utils.magic: {..} => Internal.eventTransaction)],
      ))
    },
  )

  Async.it("Throws a source-disabling error when neither price field is present", async t => {
    let mock = await MockRpcServer.make(
      ~getResult=method =>
        switch method {
        | "eth_getLogs" => JSON.Array([logJson])
        | "eth_getBlockByNumber" => blockJson
        | "eth_getTransactionReceipt" | "eth_getTransactionByHash" =>
          JSON.Object(Dict.fromArray([("gasUsed", JSON.String("0x5208"))]))
        | _ => JSON.Null
        },
    )
    let (source, eventConfig, addressStore) = makeEgpSource(~mock)

    let caught = try {
      let result = try {
        let _ = await source->invoke(~eventConfig, ~addressStore)
        None
      } catch {
      | Source.GetItemsError(FailedGettingFieldSelection({message, blockNumber})) =>
        Some((message, blockNumber))
      }
      mock.close()
      result
    } catch {
    | exn =>
      mock.close()
      throw(exn)
    }

    t.expect(caught).toEqual(
      Some((
        "Neither \"effectiveGasPrice\" nor \"gasPrice\" is present in the RPC response for the transaction. Remove \"effectiveGasPrice\" from the field selection, or index this chain via HyperSync.",
        100,
      )),
    )
  })
})

describe("RpcSource - SourceManager loads missing store data", () => {
  let sighash = "0xcf16a92280c1bbb43f72d31126b724d508df2877835849e8744017ab36a9b47f"
  let transactionHash = "0x27e26f21f744064a4af53810d8002bbd7208a2ca4865503a99b9c529e5cff5ea"
  let mockAddress = Envio.TestHelpers.Addresses.mockAddresses[0]->Option.getOrThrow

  Async.it(
    "executeQuery keeps refetching the missing receipt until the response is complete",
    async t => {
      let eventConfig = {
        ...EventRegistration.evmOnEventRegistration(~id=sighash, ~transactionFieldNames=[GasUsed]),
        index: 0,
      }

      let logJson = JSON.Object(
        Dict.fromArray([
          ("address", JSON.String(mockAddress->Address.toString)),
          ("topics", JSON.Array([JSON.String(sighash)])),
          ("data", JSON.String("0x")),
          ("blockNumber", JSON.String("0x64")),
          ("transactionHash", JSON.String(transactionHash)),
          ("transactionIndex", JSON.String("0x1")),
          (
            "blockHash",
            JSON.String("0x0000000000000000000000000000000000000000000000000000000000000b64"),
          ),
          ("logIndex", JSON.String("0x2")),
          ("removed", JSON.Boolean(false)),
        ]),
      )
      let blockJson = JSON.Object(
        Dict.fromArray([
          ("number", JSON.String("0x64")),
          ("timestamp", JSON.String("0x64")),
          (
            "hash",
            JSON.String("0x0000000000000000000000000000000000000000000000000000000000000b64"),
          ),
          (
            "parentHash",
            JSON.String("0x0000000000000000000000000000000000000000000000000000000000000b63"),
          ),
        ]),
      )

      // The receipt lags behind the logs for two lookups, like a load-balanced
      // node drifting around the head, then catches up.
      let receiptCalls = ref(0)
      let mock = await MockRpcServer.make(
        ~getResult=method =>
          switch method {
          | "eth_getLogs" => JSON.Array([logJson])
          | "eth_getBlockByNumber" => blockJson
          | "eth_getTransactionReceipt" =>
            receiptCalls := receiptCalls.contents + 1
            receiptCalls.contents <= 2
              ? JSON.Null
              : JSON.Object(Dict.fromArray([("gasUsed", JSON.String("0x5208"))]))
          | _ => JSON.Null
          },
      )

      let addressStore = makeAddressStore(
        ~onEventRegistrations=[eventConfig],
        ~addresses=[
          {
            address: mockAddress,
            contractName: eventConfig.eventConfig.contractName,
            registrationBlock: -1,
          },
        ],
      )
      let source = RpcSource.make({
        url: mock.url,
        chainId,
        onEventRegistrations: [eventConfig],
        sourceFor: Sync,
        syncConfig: EvmChain.getSyncConfig({}),
        lowercaseAddresses: false,
        addressStore,
      })
      let sourceManager = SourceManager.make(~isRealtime=false, ~sources=[source])

      let result = try {
        let response = await sourceManager->SourceManager.executeQuery(
          ~query={
            partitionId: "0",
            fromBlock: 0,
            toBlock: Some(100),
            isChunk: false,
            itemsTarget: Some(5000),
            itemsEst: 0,
            selection: {
              dependsOnAddresses: true,
              onEventRegistrations: [(eventConfig :> Internal.onEventRegistration)],
            },
            addresses: addressStore->AddressStore.makeSet(
              ~contractName=eventConfig.eventConfig.contractName,
            ),
          },
          ~knownHeight=100,
          ~isRealtime=false,
        )
        let materialized =
          await response.transactionStore
          ->Option.getOrThrow
          ->TransactionStore.materialize(
            ~blockNumbers=[100],
            ~transactionIndices=[1],
            ~masks=[Evm.eventTransactionFieldMask(Utils.Set.fromArray(["gasUsed"]))],
          )
        let getLogsRequestCount =
          mock.requests->Array.filter(body => body->String.includes("eth_getLogs"))->Array.length
        mock.close()
        (
          response.parsedQueueItems->Array.length,
          receiptCalls.contents,
          getLogsRequestCount,
          materialized,
        )
      } catch {
      | exn =>
        mock.close()
        throw(exn)
      }

      // The logs are fetched once; only the missing receipt is retried, and the
      // returned response's store already carries the receipt's data.
      t.expect(result).toEqual((
        1,
        3,
        1,
        [{"gasUsed": 21000n}->(Utils.magic: {..} => Internal.eventTransaction)],
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
      let eventConfig = {
        ...EventRegistration.evmOnEventRegistration(
          ~id=sighash,
          // Two indexed params so the log carries the topic1/topic2 values the
          // OR branches filter on and decodes cleanly (derived topicCount 3).
          ~paramsMetadata=[
            {name: "a", abiType: "uint256", indexed: true},
            {name: "b", abiType: "uint256", indexed: true},
          ],
          ~eventFilters=[
            {
              topic0: [sighash->EvmTypes.Hex.fromStringUnsafe],
              topic1: Values([
                "0x0000000000000000000000000000000000000000000000000000000000000001"->EvmTypes.Hex.fromStringUnsafe,
              ]),
              topic2: Values([]),
              topic3: Values([]),
            },
            {
              topic0: [sighash->EvmTypes.Hex.fromStringUnsafe],
              topic1: Values([]),
              topic2: Values([
                "0x0000000000000000000000000000000000000000000000000000000000000002"->EvmTypes.Hex.fromStringUnsafe,
              ]),
              topic3: Values([]),
            },
          ],
        ),
        index: 0,
      }

      // Carries both indexed topics the OR branches filter on, so a real
      // provider returns it for either server-side filter; routing re-checks
      // the registration's topic filters against these values.
      let logJson = JSON.Object(
        Dict.fromArray([
          ("address", JSON.String(mockAddress->Address.toString)),
          (
            "topics",
            JSON.Array([
              JSON.String(sighash),
              JSON.String("0x0000000000000000000000000000000000000000000000000000000000000001"),
              JSON.String("0x0000000000000000000000000000000000000000000000000000000000000002"),
            ]),
          ),
          ("data", JSON.String("0x")),
          ("blockNumber", JSON.String("0x64")),
          (
            "transactionHash",
            JSON.String("0x27e26f21f744064a4af53810d8002bbd7208a2ca4865503a99b9c529e5cff5ea"),
          ),
          ("transactionIndex", JSON.String("0x1")),
          (
            "blockHash",
            JSON.String("0x0000000000000000000000000000000000000000000000000000000000000b64"),
          ),
          ("logIndex", JSON.String("0x2")),
          ("removed", JSON.Boolean(false)),
        ]),
      )
      let blockJson = JSON.Object(
        Dict.fromArray([
          ("number", JSON.String("0x64")),
          ("timestamp", JSON.String("0x64")),
          (
            "hash",
            JSON.String("0x0000000000000000000000000000000000000000000000000000000000000b64"),
          ),
          (
            "parentHash",
            JSON.String("0x0000000000000000000000000000000000000000000000000000000000000b63"),
          ),
        ]),
      )

      let mock = await MockRpcServer.make(
        ~getResult=method =>
          switch method {
          | "eth_getLogs" => JSON.Array([logJson])
          | "eth_getBlockByNumber" => blockJson
          | _ => JSON.Null
          },
      )

      let addressStore = makeAddressStore(
        ~onEventRegistrations=[eventConfig],
        ~addresses=[
          {
            address: mockAddress,
            contractName: eventConfig.eventConfig.contractName,
            registrationBlock: -1,
          },
        ],
      )
      let source = RpcSource.make({
        url: mock.url,
        chainId,
        onEventRegistrations: [eventConfig],
        sourceFor: Sync,
        syncConfig: EvmChain.getSyncConfig({}),
        lowercaseAddresses: false,
        addressStore,
      })

      let result = try {
        let page = await source.getItemsOrThrow(
          ~fromBlock=0,
          ~toBlock=Some(100),
          ~addressSet=addressStore->AddressStore.makeSet(
            ~contractName=eventConfig.eventConfig.contractName,
          ),
          ~knownHeight=100,
          ~partitionId="0",
          ~selection={
            dependsOnAddresses: true,
            onEventRegistrations: [(eventConfig :> Internal.onEventRegistration)],
          },
          ~itemsTarget=Some(5000),
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

describe("RpcSource - builds partition log selections end to end", () => {
  let hexId = suffix => "0x" ++ "00"->String.repeat(31) ++ suffix
  let sighash1 = hexId("01")
  let sighash2 = hexId("02")
  let sighash3 = hexId("03")
  let sighash4 = hexId("04")
  let excludedSighash = hexId("05")
  let mockAddress = Envio.TestHelpers.Addresses.mockAddresses[0]->Option.getOrThrow

  let summarizeGetLogsRequest = requestBody => {
    let request = requestBody->JSON.parseOrThrow->JSON.Decode.object
    let method =
      request
      ->Option.flatMap(Dict.get(_, "method"))
      ->Option.flatMap(JSON.Decode.string)

    switch (method, request->Option.flatMap(Dict.get(_, "params"))) {
    | (Some("eth_getLogs"), Some(JSON.Array([JSON.Object(filter)]))) =>
      let address = filter->Dict.get("address")->Option.getOr(JSON.Null)->JSON.stringify
      let topics = filter->Dict.get("topics")->Option.getOr(JSON.Array([]))->JSON.stringify
      Some(`address=${address};topics=${topics}`)
    | _ => None
    }
  }

  Async.it("builds the partition's real RPC filters without a test-only query API", async t => {
    let addressBound = {
      ...EventRegistration.evmOnEventRegistration(~id=sighash1),
      index: 0,
    }
    let wildcardA = {
      ...EventRegistration.evmOnEventRegistration(
        ~id=sighash2,
        ~contractName="WildcardA",
        ~isWildcard=true,
      ),
      index: 1,
    }
    let wildcardB = {
      ...EventRegistration.evmOnEventRegistration(
        ~id=sighash3,
        ~contractName="WildcardB",
        ~isWildcard=true,
      ),
      index: 2,
    }
    let wildcardByAddress = {
      ...EventRegistration.evmOnEventRegistration(
        ~id=sighash4,
        ~isWildcard=true,
        ~dependsOnAddresses=true,
      ),
      index: 3,
    }
    let excluded = {
      ...EventRegistration.evmOnEventRegistration(
        ~id=excludedSighash,
        ~contractName="Excluded",
        ~isWildcard=true,
      ),
      index: 4,
    }
    let allRegistrations = [addressBound, wildcardA, wildcardB, wildcardByAddress, excluded]
    let selectedRegistrations = [addressBound, wildcardA, wildcardB, wildcardByAddress]

    let blockJson = JSON.Object(
      Dict.fromArray([
        ("number", JSON.String("0x64")),
        ("timestamp", JSON.String("0x64")),
        ("hash", JSON.String("0x0000000000000000000000000000000000000000000000000000000000000b64")),
        (
          "parentHash",
          JSON.String("0x0000000000000000000000000000000000000000000000000000000000000b63"),
        ),
      ]),
    )
    let mock = await MockRpcServer.make(
      ~getResult=method =>
        switch method {
        | "eth_getLogs" => JSON.Array([])
        | "eth_getBlockByNumber" => blockJson
        | _ => JSON.Null
        },
    )
    let addressStore = makeAddressStore(
      ~onEventRegistrations=allRegistrations,
      ~addresses=[
        {
          address: mockAddress,
          contractName: addressBound.eventConfig.contractName,
          registrationBlock: -1,
        },
      ],
    )
    let source = RpcSource.make({
      url: mock.url,
      chainId,
      onEventRegistrations: allRegistrations,
      sourceFor: Sync,
      syncConfig: EvmChain.getSyncConfig({}),
      lowercaseAddresses: false,
      addressStore,
    })

    let (page, filters) = try {
      let page = await source.getItemsOrThrow(
        ~fromBlock=0,
        ~toBlock=Some(100),
        ~addressSet=addressStore->AddressStore.makeSet(
          ~contractName=addressBound.eventConfig.contractName,
        ),
        ~knownHeight=100,
        ~partitionId="selection-e2e",
        ~selection={
          dependsOnAddresses: true,
          onEventRegistrations: selectedRegistrations->Array.map(
            reg => (reg :> Internal.onEventRegistration),
          ),
        },
        ~itemsTarget=Some(5000),
        ~retry=0,
        ~logger=Logging.createChild(~params={"test": "RpcSource selection e2e"}),
      )
      let filters =
        mock.requests
        ->Array.filterMap(summarizeGetLogsRequest)
        ->Array.toSorted(String.compare)
      mock.close()
      (page, filters)
    } catch {
    | exn =>
      mock.close()
      throw(exn)
    }

    let address = mockAddress->Address.toString
    let addressTopic =
      "0x000000000000000000000000" ++ address->String.toLowerCase->String.slice(~start=2)
    let expectedFilters =
      [
        `address=["${address}"];topics=[["${sighash1}"]]`,
        `address=null;topics=[["${sighash2}","${sighash3}"]]`,
        `address=null;topics=[["${sighash4}"],["${addressTopic}"]]`,
      ]->Array.toSorted(String.compare)

    t.expect((
      filters,
      page.parsedQueueItems->Array.length,
      page.latestFetchedBlockNumber,
    )).toEqual((expectedFilters, 0, 100))
  })
})

describe("RpcSource - getItemsOrThrow with a skip-all event filter", () => {
  let sighash = "0x8c5be1e5ebec7d5bd14f71427d1e84f3dd0314c0f7b2291e5b200ac8c7c3b925"

  Async.it(
    "Advances the range without an eth_getLogs when the filter resolves to no selections",
    async t => {
      // `where: false` compiles to an empty topic-selection set, so there is
      // nothing to query — the batch must advance the cursor without issuing an
      // eth_getLogs (and without throwing, which the pre-fan-out code did).
      let eventConfig = {
        ...EventRegistration.evmOnEventRegistration(
          ~id=sighash,
          ~isWildcard=true,
          ~eventFilters=[],
        ),
        index: 0,
      }

      // Echo the requested block number so `latestFetchedBlockNumber` reflects
      // the block the source actually loaded, not a constant baked into the mock.
      let mock = await MockRpcServer.makeWithParams(
        ~getResult=(~method, ~params) =>
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
                (
                  "hash",
                  JSON.String("0x0000000000000000000000000000000000000000000000000000000000000b64"),
                ),
                (
                  "parentHash",
                  JSON.String("0x0000000000000000000000000000000000000000000000000000000000000b63"),
                ),
              ]),
            )
          | _ => JSON.Null
          },
      )

      // Wildcard-only selection: the partition carries no addresses.
      let addressStore = makeAddressStore(~onEventRegistrations=[eventConfig])
      let source = RpcSource.make({
        url: mock.url,
        chainId,
        onEventRegistrations: [eventConfig],
        sourceFor: Sync,
        syncConfig: EvmChain.getSyncConfig({}),
        lowercaseAddresses: false,
        addressStore,
      })

      let result = try {
        let page = await source.getItemsOrThrow(
          ~fromBlock=0,
          ~toBlock=Some(100),
          ~addressSet=addressStore->AddressStore.emptySet,
          ~knownHeight=100,
          ~partitionId="0",
          ~selection={
            dependsOnAddresses: false,
            onEventRegistrations: [(eventConfig :> Internal.onEventRegistration)],
          },
          ~itemsTarget=Some(5000),
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

describe("RpcSource - getItemsOrThrow scopes filters to each contract's addresses", () => {
  let sighash = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"
  let filterTopic1 = "0x0000000000000000000000000000000000000000000000000000000000000001"
  let addrA = Envio.TestHelpers.Addresses.mockAddresses[0]->Option.getOrThrow
  let addrB = Envio.TestHelpers.Addresses.mockAddresses[1]->Option.getOrThrow

  // Regression guard against a cross-contract filter leak: ContractA filters on
  // topic1, ContractB is unfiltered, and both share topic0. Each contract's query
  // must be scoped to its own addresses — otherwise ContractB's `[sig]` query
  // would also cover ContractA's address, fetch a ContractA log, and route it back
  // to ContractA (by address), bypassing its filter since routing never re-applies
  // the topic filter.
  Async.it(
    "a filtered contract must not receive a log fetched by another contract's query",
    async t => {
      let eventA = {
        ...EventRegistration.evmOnEventRegistration(
          ~contractName="ContractA",
          ~id=sighash,
          ~eventFilters=[
            {
              topic0: [sighash->EvmTypes.Hex.fromStringUnsafe],
              topic1: Values([filterTopic1->EvmTypes.Hex.fromStringUnsafe]),
              topic2: Values([]),
              topic3: Values([]),
            },
          ],
        ),
        index: 0,
      }
      let eventB = {
        ...EventRegistration.evmOnEventRegistration(
          ~contractName="ContractB",
          ~id=sighash,
          ~eventFilters=[
            {
              topic0: [sighash->EvmTypes.Hex.fromStringUnsafe],
              topic1: Values([]),
              topic2: Values([]),
              topic3: Values([]),
            },
          ],
        ),
        index: 1,
      }

      // A log emitted by ContractA's address, carrying only topic0 (so it does
      // NOT match ContractA's topic1 filter). ContractA's own query would never
      // return it; only ContractB's unfiltered query can.
      let leakedLog = JSON.Object(
        Dict.fromArray([
          ("address", JSON.String(addrA->Address.toString)),
          ("topics", JSON.Array([JSON.String(sighash)])),
          ("data", JSON.String("0x")),
          ("blockNumber", JSON.String("0x64")),
          (
            "transactionHash",
            JSON.String("0x27e26f21f744064a4af53810d8002bbd7208a2ca4865503a99b9c529e5cff5ea"),
          ),
          ("transactionIndex", JSON.String("0x1")),
          (
            "blockHash",
            JSON.String("0x0000000000000000000000000000000000000000000000000000000000000b64"),
          ),
          ("logIndex", JSON.String("0x2")),
          ("removed", JSON.Boolean(false)),
        ]),
      )
      let blockJson = JSON.Object(
        Dict.fromArray([
          ("number", JSON.String("0x64")),
          ("timestamp", JSON.String("0x64")),
          (
            "hash",
            JSON.String("0x0000000000000000000000000000000000000000000000000000000000000b64"),
          ),
          (
            "parentHash",
            JSON.String("0x0000000000000000000000000000000000000000000000000000000000000b63"),
          ),
        ]),
      )

      // Honor the query's `address` and `topics` like a real eth_getLogs, so a
      // per-contract-scoped query (the fix) would exclude addrA and return nothing.
      let queryReturnsLeakedLog = (params: JSON.t) =>
        switch params {
        | JSON.Array([JSON.Object(filter)]) =>
          let addressOk = switch filter->Dict.get("address") {
          | Some(JSON.Array(addrs)) =>
            addrs->Array.some(
              a =>
                switch a {
                | JSON.String(s) =>
                  s->String.toLowerCase == addrA->Address.toString->String.toLowerCase
                | _ => false
                },
            )
          | _ => true
          }
          let topics = switch filter->Dict.get("topics") {
          | Some(JSON.Array(t)) => t
          | _ => []
          }
          let topic0Ok = switch topics->Array.get(0) {
          | Some(JSON.Array(hs)) => hs->Array.some(h => h == JSON.String(sighash))
          | _ => true
          }
          // The leaked log has no topic1, so any topic1 constraint excludes it.
          let topic1Ok = switch topics->Array.get(1) {
          | Some(JSON.Array(_)) => false
          | _ => true
          }
          addressOk && topic0Ok && topic1Ok
        | _ => false
        }

      let mock = await MockRpcServer.makeWithParams(
        ~getResult=(~method, ~params) =>
          switch method {
          | "eth_getLogs" =>
            queryReturnsLeakedLog(params) ? JSON.Array([leakedLog]) : JSON.Array([])
          | "eth_getBlockByNumber" => blockJson
          | _ => JSON.Null
          },
      )

      let addressStore = makeAddressStore(
        ~onEventRegistrations=[eventA, eventB],
        ~addresses=[
          {address: addrA, contractName: "ContractA", registrationBlock: -1},
          {address: addrB, contractName: "ContractB", registrationBlock: -1},
        ],
      )
      let source = RpcSource.make({
        url: mock.url,
        chainId,
        onEventRegistrations: [eventA, eventB],
        sourceFor: Sync,
        syncConfig: EvmChain.getSyncConfig({}),
        lowercaseAddresses: false,
        addressStore,
      })

      let result = try {
        let page = await source.getItemsOrThrow(
          ~fromBlock=0,
          ~toBlock=Some(100),
          ~addressSet=addressStore
          ->AddressStore.makeSet(~contractName="ContractA")
          ->AddressSet.merge(addressStore->AddressStore.makeSet(~contractName="ContractB")),
          ~knownHeight=100,
          ~partitionId="0",
          ~selection={
            dependsOnAddresses: true,
            onEventRegistrations: [
              (eventA :> Internal.onEventRegistration),
              (eventB :> Internal.onEventRegistration),
            ],
          },
          ~itemsTarget=Some(5000),
          ~retry=0,
          ~logger=Logging.createChild(~params={"test": "RpcSource pooled leak"}),
        )
        mock.close()
        page
      } catch {
      | exn =>
        mock.close()
        throw(exn)
      }

      // The addrA log matches neither contract's own scoped query (ContractA's
      // filters it out on topic1; ContractB's query never covers addrA), so
      // nothing is emitted.
      t.expect(result.parsedQueueItems->Array.length).toEqual(0)
    },
  )
})
