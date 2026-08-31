open Vitest
open Internal

let testApiToken =
  Env.envioApiToken->Option.getOrThrow(
    ~message="ENVIO_API_TOKEN env var must be set to run RpcSource tests",
  )

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
      blockStore: BlockStore.make(~ecosystem=Ecosystem.Evm, ~shouldChecksum=true),
      transactionStore: TransactionStore.make(~ecosystem=Ecosystem.Evm, ~shouldChecksum=true),
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
      blockStore: BlockStore.make(~ecosystem=Ecosystem.Evm, ~shouldChecksum=true),
      transactionStore: TransactionStore.make(~ecosystem=Ecosystem.Evm, ~shouldChecksum=true),
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

let makeStores = (~lowercaseAddresses=true) => (
  BlockStore.make(~ecosystem=Ecosystem.Evm, ~shouldChecksum=!lowercaseAddresses),
  TransactionStore.make(~ecosystem=Ecosystem.Evm, ~shouldChecksum=!lowercaseAddresses),
)

let chainId = 1->ChainId.fromInt

// A block response carrying the reorg fields the client reads for every block,
// whatever the selection is.
let blockJsonAt = number => JSON.Object(
  Dict.fromArray([
    ("number", JSON.String(number)),
    ("timestamp", JSON.String("0x64")),
    ("hash", JSON.String("0x0000000000000000000000000000000000000000000000000000000000000b64")),
    (
      "parentHash",
      JSON.String("0x0000000000000000000000000000000000000000000000000000000000000b63"),
    ),
  ]),
)

// A block response has to be the block that was asked for, so echo the
// requested number back rather than answering with a fixed one.
let echoedBlockJson = requestBody =>
  requestBody
  ->JSON.parseOrThrow
  ->JSON.Decode.object
  ->Option.flatMap(Dict.get(_, "params"))
  ->Option.flatMap(JSON.Decode.array)
  ->Option.flatMap(params => params->Array.get(0))
  ->Option.flatMap(JSON.Decode.string)
  ->Option.getOr("0x2710")
  ->blockJsonAt

// Field selection is exercised through the source rather than through a parser:
// what a handler ends up seeing is the product of the request the client
// chooses to make, what it stores, and what materialisation reads back, and
// only the whole path can be wrong in a way a user notices.
describe("RpcSource - field selection end to end", () => {
  let sighash = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"
  let mockAddress = Envio.TestHelpers.Addresses.mockAddresses[0]->Option.getOrThrow
  let txHash = "0x" ++ "ab"->String.repeat(32)
  let blockHash = "0x" ++ "b1"->String.repeat(32)
  let parentHash = "0x" ++ "b0"->String.repeat(32)

  let logJson = JSON.parseOrThrow(
    `{"address":"${mockAddress->Address.toString}","topics":["${sighash}"],"data":"0x","blockNumber":"0x64","transactionHash":"${txHash}","transactionIndex":"0x1","blockHash":"${blockHash}","logIndex":"0x0","removed":false}`,
  )

  // A provider that answers every method the source can ask for. Each test
  // asserts on `mock.requests` to pin which of them were actually needed.
  let startProvider = (~transaction=?, ~receipt=?, ~block=?) =>
    MockRpcServer.makeWithParams(~getResult=(~method, ~params as _) =>
      switch method {
      | "eth_getLogs" => JSON.Array([logJson])
      | "eth_getBlockByNumber" =>
        block->Option.getOr(
          JSON.parseOrThrow(
            `{"number":"0x64","timestamp":"0x5f5e100","hash":"${blockHash}","parentHash":"${parentHash}","miner":"0xAbC0000000000000000000000000000000000123","gasUsed":"0x2a","baseFeePerGas":null}`,
          ),
        )
      | "eth_getTransactionByHash" =>
        transaction->Option.getOr(
          JSON.parseOrThrow(
            `{"hash":"${txHash}","gas":"0x5208","gasPrice":"0x7","input":"0xdeadbeef","from":"0xAbC0000000000000000000000000000000000123","to":null,"nonce":"0x1","unknownExtraField":"ignored"}`,
          ),
        )
      | "eth_getTransactionReceipt" =>
        receipt->Option.getOr(
          JSON.parseOrThrow(`{"gasUsed":"0x5208","cumulativeGasUsed":"0x5209","effectiveGasPrice":"0x9","status":"0x1","from":"0xAbC0000000000000000000000000000000000123","to":null,"l1FeeScalar":"1.5"}`),
        )
      | _ => JsError.throwWithMessage(`Unexpected RPC method ${method}`)
      }
    )

  // Fetch one range and resolve the payloads the way batch prep does, so the
  // assertions read exactly what a handler would.
  let fetchPayloads = async (
    ~mock: MockRpcServer.t,
    ~blockFieldNames=[],
    ~transactionFieldNames=[],
    ~lowercaseAddresses=true,
    ~stores=?,
  ) => {
    let registration = {
      ...EventRegistration.evmOnEventRegistration(
        ~id=sighash,
        ~blockFieldNames,
        ~transactionFieldNames,
      ),
      index: 0,
    }
    let addressStore = makeAddressStore(
      ~onEventRegistrations=[registration],
      ~addresses=[
        {
          address: mockAddress,
          contractName: registration.eventConfig.contractName,
          registrationBlock: -1,
        },
      ],
    )
    let (blockStore, transactionStore) = stores->Option.getOr(makeStores(~lowercaseAddresses))
    let source = RpcSource.make({
      url: mock.url,
      chainId,
      onEventRegistrations: [registration],
      sourceFor: Sync,
      syncConfig: EvmChain.getSyncConfig({}),
      lowercaseAddresses,
      addressStore,
      blockStore,
      transactionStore,
    })
    let response = await source.getItemsOrThrow(
      ~fromBlock=100,
      ~toBlock=Some(100),
      ~addressSet=addressStore->AddressStore.makeSet(
        ~contractName=registration.eventConfig.contractName,
      ),
      ~knownHeight=100,
      ~partitionId="0",
      ~selection={
        dependsOnAddresses: true,
        onEventRegistrations: [(registration :> Internal.onEventRegistration)],
      },
      ~itemsTarget=Some(5000),
      ~retry=0,
      ~logger=Logging.createChild(~params={"test": "RpcSource field selection"}),
    )
    await response->RpcSourcePins.applyPage(~blockStore, ~transactionStore)
    response.parsedQueueItems->Array.map(item =>
      switch item {
      | Internal.Event({payload}) => payload->Evm.toPayload
      | Internal.Block(_) => JsError.throwWithMessage("unexpected onBlock item")
      }
    )
  }

  let countMethod = (mock: MockRpcServer.t, method) =>
    mock.requests->Array.filter(body => body->String.includes(`"${method}"`))->Array.length

  Async.it("Reads a transaction-only selection from the transaction alone", async t => {
    let mock = await startProvider()
    let payloads = await fetchPayloads(~mock, ~transactionFieldNames=[Gas, Input, Nonce])
    let counts = (
      mock->countMethod("eth_getTransactionByHash"),
      mock->countMethod("eth_getTransactionReceipt"),
    )
    mock.close()
    t.expect((payloads->Array.map(p => p.transaction), counts)).toEqual((
      [Some({"gas": 21000n, "input": "0xdeadbeef", "nonce": 1n}->Obj.magic)],
      (1, 0),
    ))
  })

  Async.it("Reads a receipt-only selection from the receipt alone", async t => {
    let mock = await startProvider()
    let payloads = await fetchPayloads(
      ~mock,
      ~transactionFieldNames=[GasUsed, CumulativeGasUsed, Status],
    )
    let counts = (
      mock->countMethod("eth_getTransactionByHash"),
      mock->countMethod("eth_getTransactionReceipt"),
    )
    mock.close()
    t.expect((payloads->Array.map(p => p.transaction), counts)).toEqual((
      [Some({"gasUsed": 21000n, "cumulativeGasUsed": 21001n, "status": 1}->Obj.magic)],
      (0, 1),
    ))
  })

  Async.it("Serves a selection carried by both responses from the transaction", async t => {
    let mock = await startProvider()
    let payloads = await fetchPayloads(~mock, ~transactionFieldNames=[From, To])
    let counts = (
      mock->countMethod("eth_getTransactionByHash"),
      mock->countMethod("eth_getTransactionReceipt"),
    )
    mock.close()
    // `to` is null on this transaction: a contract creation, not a gap.
    t.expect((payloads->Array.map(p => p.transaction), counts)).toEqual((
      [Some({"from": "0xabc0000000000000000000000000000000000123", "to": None}->Obj.magic)],
      (1, 0),
    ))
  })

  // `from`/`to`/`type` ride on both responses, so a selection that also needs a
  // receipt-only field must read them off the receipt rather than pay for a
  // second request. Nothing marks them missing, so a regression here would show
  // up as `undefined` in a handler instead of an error.
  Async.it("Serves a selection carried by both responses from the receipt", async t => {
    let mock = await startProvider(
      ~receipt=JSON.parseOrThrow(`{"gasUsed":"0x5208","from":"0x1111111111111111111111111111111111111111","to":"0x2222222222222222222222222222222222222222","type":"0x2"}`),
    )
    let payloads = await fetchPayloads(~mock, ~transactionFieldNames=[From, To, Type, GasUsed])
    let counts = (
      mock->countMethod("eth_getTransactionByHash"),
      mock->countMethod("eth_getTransactionReceipt"),
    )
    mock.close()
    t.expect((payloads->Array.map(p => p.transaction), counts)).toEqual((
      [
        Some(
          {
            "from": "0x1111111111111111111111111111111111111111",
            "to": "0x2222222222222222222222222222222222222222",
            "type": 2,
            "gasUsed": 21000n,
          }->Obj.magic,
        ),
      ],
      (0, 1),
    ))
  })

  Async.it("Takes hash and transactionIndex off the log without a request", async t => {
    let mock = await startProvider()
    let payloads = await fetchPayloads(~mock, ~transactionFieldNames=[Hash, TransactionIndex])
    let counts = (
      mock->countMethod("eth_getTransactionByHash"),
      mock->countMethod("eth_getTransactionReceipt"),
    )
    mock.close()
    t.expect((payloads->Array.map(p => p.transaction), counts)).toEqual((
      [Some({"hash": txHash, "transactionIndex": 1}->Obj.magic)],
      (0, 0),
    ))
  })

  Async.it("Falls back to the transaction's gasPrice when the receipt omits it", async t => {
    let mock = await startProvider(
      ~receipt=JSON.parseOrThrow(`{"gasUsed":"0x5208","status":"0x1"}`),
    )
    let payloads = await fetchPayloads(~mock, ~transactionFieldNames=[EffectiveGasPrice])
    mock.close()
    t.expect(payloads->Array.map(p => p.transaction)).toEqual([
      Some({"effectiveGasPrice": 7n}->Obj.magic),
    ])
  })

  Async.it("Reports a receipt with neither effectiveGasPrice nor gasPrice", async t => {
    let mock = await startProvider(
      ~transaction=JSON.parseOrThrow(`{"hash":"${txHash}"}`),
      ~receipt=JSON.parseOrThrow(`{"gasUsed":"0x5208"}`),
    )
    let caught = try {
      let _ = await fetchPayloads(~mock, ~transactionFieldNames=[EffectiveGasPrice])
      None
    } catch {
    | Source.GetItemsError(FailedGettingFieldSelection({message})) => Some(message)
    }
    mock.close()
    t.expect(caught->Option.map(m => m->String.includes("effectiveGasPrice"))).toEqual(Some(true))
  })

  Async.it("Reports a selected field the provider did not return", async t => {
    let mock = await startProvider(~transaction=JSON.parseOrThrow(`{"hash":"${txHash}"}`))
    let caught = try {
      let _ = await fetchPayloads(~mock, ~transactionFieldNames=[Gas])
      None
    } catch {
    | Source.GetItemsError(FailedGettingFieldSelection({message, blockNumber})) =>
      // The block it happened on is what makes an unservable selection
      // diagnosable, so it names the block rather than the range's end.
      Some((message->String.includes("gas"), blockNumber))
    }
    mock.close()
    t.expect(caught).toEqual(Some((true, 100)))
  })

  // A garbled value and a response for the wrong block are both one node
  // answering badly, not a selection the chain cannot serve. Reporting them as
  // a field-selection failure disables the source for good — on a chain with a
  // single RPC the indexer then stops — so they have to stay retryable.
  Async.it("Retries rather than disabling the source on a value it cannot decode", async t => {
    let mock = await startProvider(
      ~transaction=JSON.parseOrThrow(`{"hash":"${txHash}","gas":"not-hex"}`),
    )
    let caught = try {
      let _ = await fetchPayloads(~mock, ~transactionFieldNames=[Gas])
      None
    } catch {
    | Source.GetItemsError(FailedGettingItems({retry: WithBackoff({message})})) => Some(message)
    }
    mock.close()
    t.expect(caught->Option.map(m => m->String.includes("gas"))).toEqual(Some(true))
  })

  // Every fetched block is read for its reorg fields whether or not the user
  // selected them, so a response missing one says nothing about whether the
  // selection is servable — every EVM chain has a block hash. Judging it the
  // same way as a selected field would disable the source over one bad answer
  // to a question the user never asked.
  Async.it("Retries when the response omits a field only the reorg check needs", async t => {
    let mock = await startProvider(
      ~block=JSON.parseOrThrow(
        `{"number":"0x64","timestamp":"0x5f5e100","parentHash":"${parentHash}","gasUsed":"0x2a"}`,
      ),
    )
    let caught = try {
      let _ = await fetchPayloads(~mock, ~blockFieldNames=[GasUsed])
      None
    } catch {
    | Source.GetItemsError(FailedGettingItems({retry: WithBackoff({message})})) =>
      Some(message->String.includes("hash"))
    }
    mock.close()
    t.expect(caught).toEqual(Some(true))
  })

  Async.it("Still disables the source when a selected block field is missing", async t => {
    let mock = await startProvider(
      ~block=JSON.parseOrThrow(
        `{"number":"0x64","timestamp":"0x5f5e100","hash":"${blockHash}","parentHash":"${parentHash}"}`,
      ),
    )
    let caught = try {
      let _ = await fetchPayloads(~mock, ~blockFieldNames=[GasUsed])
      None
    } catch {
    | Source.GetItemsError(FailedGettingFieldSelection({message})) =>
      Some(message->String.includes("gasUsed"))
    }
    mock.close()
    t.expect(caught).toEqual(Some(true))
  })

  Async.it("Retries rather than disabling the source on a wrong-block response", async t => {
    // A load-balanced provider can answer eth_getBlockByNumber from a node that
    // has drifted, returning the neighbouring block.
    let mock = await startProvider(
      ~block=JSON.parseOrThrow(
        `{"number":"0x65","timestamp":"0x5f5e100","hash":"${blockHash}","parentHash":"${parentHash}"}`,
      ),
    )
    let caught = try {
      let _ = await fetchPayloads(~mock, ~blockFieldNames=[Timestamp])
      None
    } catch {
    | Source.GetItemsError(FailedGettingItems({retry: WithBackoff({message})})) => Some(message)
    }
    mock.close()
    t.expect(
      caught->Option.map(m => m->String.includes("block 100") && m->String.includes("block 101")),
    ).toEqual(Some(true))
  })

  Async.it("Reads selected block fields, keeping a nullable one absent", async t => {
    let mock = await startProvider()
    let payloads = await fetchPayloads(
      ~mock,
      ~blockFieldNames=[Number, Timestamp, Hash, GasUsed, BaseFeePerGas],
    )
    mock.close()
    t.expect(payloads->Array.map(p => p.block)).toEqual([
      Some(
        {
          "number": 100,
          "timestamp": 100000000,
          "hash": blockHash,
          "gasUsed": 42n,
          "baseFeePerGas": None,
        }->Obj.magic,
      ),
    ])
  })

  Async.it("Normalizes addresses to the chain's configured casing", async t => {
    let minerWith = async (~lowercaseAddresses) => {
      let mock = await startProvider()
      let payloads = await fetchPayloads(~mock, ~blockFieldNames=[Miner], ~lowercaseAddresses)
      mock.close()
      payloads->Array.map(p => p.block)
    }
    let lowercased = await minerWith(~lowercaseAddresses=true)
    let checksummed = await minerWith(~lowercaseAddresses=false)
    t.expect((lowercased, checksummed)).toEqual((
      [Some({"miner": "0xabc0000000000000000000000000000000000123"}->Obj.magic)],
      [Some({"miner": "0xABc0000000000000000000000000000000000123"}->Obj.magic)],
    ))
  })

  Async.it("Normalizes transaction addresses to the chain's configured casing", async t => {
    let addressesWith = async (~lowercaseAddresses) => {
      let mock = await startProvider(
        ~receipt=JSON.parseOrThrow(`{"gasUsed":"0x5208","from":"0xAbC0000000000000000000000000000000000123","contractAddress":"0xdEf0000000000000000000000000000000000456"}`),
      )
      let payloads = await fetchPayloads(
        ~mock,
        ~transactionFieldNames=[From, ContractAddress, GasUsed],
        ~lowercaseAddresses,
      )
      mock.close()
      payloads->Array.map(p => p.transaction)
    }
    let lowercased = await addressesWith(~lowercaseAddresses=true)
    let checksummed = await addressesWith(~lowercaseAddresses=false)
    t.expect((lowercased, checksummed)).toEqual((
      [
        Some(
          {
            "from": "0xabc0000000000000000000000000000000000123",
            "contractAddress": "0xdef0000000000000000000000000000000000456",
            "gasUsed": 21000n,
          }->Obj.magic,
        ),
      ],
      [
        Some(
          {
            "from": "0xABc0000000000000000000000000000000000123",
            "contractAddress": "0xDEf0000000000000000000000000000000000456",
            "gasUsed": 21000n,
          }->Obj.magic,
        ),
      ],
    ))
  })

  Async.it("Materialises accessList and authorizationList onto the payload", async t => {
    let listAddress = "0x" ++ "22"->String.repeat(20)
    let storageKey = "0x" ++ "11"->String.repeat(32)
    let mock = await startProvider(
      ~transaction=JSON.parseOrThrow(
        `{"hash":"${txHash}","accessList":[{"address":"${listAddress}","storageKeys":["${storageKey}"]}],"authorizationList":[{"chainId":"0x1","address":"${listAddress}","nonce":"0x1","yParity":"0x0","r":"0x1","s":"0x1"}]}`,
      ),
    )
    let payloads = await fetchPayloads(
      ~mock,
      ~transactionFieldNames=[AccessList, AuthorizationList],
    )
    mock.close()
    t.expect(payloads->Array.map(p => p.transaction)).toEqual([
      Some(
        {
          "accessList": [{"address": listAddress, "storageKeys": [storageKey]}],
          "authorizationList": [
            {
              "chainId": 1n,
              "address": listAddress,
              "nonce": 1,
              "yParity": 0,
              "r": "0x1",
              "s": "0x1",
            },
          ],
        }->Obj.magic,
      ),
    ])
  })

  // A pre-EIP-2930 transaction has no `accessList` at all. Treating that as a
  // missing selected field would fail the query and disable the source.
  Async.it("Accepts a legacy transaction that carries no accessList", async t => {
    let mock = await startProvider(
      ~transaction=JSON.parseOrThrow(`{"hash":"${txHash}","gas":"0x5208"}`),
    )
    let payloads = await fetchPayloads(~mock, ~transactionFieldNames=[AccessList])
    mock.close()
    t.expect(payloads->Array.map(p => p.transaction)).toEqual([
      Some({"accessList": None}->Obj.magic),
    ])
  })

  Async.it("Reads a decimal-encoded l1FeeScalar", async t => {
    let mock = await startProvider()
    let payloads = await fetchPayloads(~mock, ~transactionFieldNames=[L1FeeScalar])
    mock.close()
    t.expect(payloads->Array.map(p => p.transaction)).toEqual([
      Some({"l1FeeScalar": 1.5}->Obj.magic),
    ])
  })

  // The reason the source consults the chain's stores at all: partitions are
  // address slices, not range slices, so several of them scan the same blocks.
  Async.it("Does not re-read a block or transaction the stores already cover", async t => {
    let stores = makeStores()
    let first = await startProvider()
    let _ = await fetchPayloads(
      ~mock=first,
      ~blockFieldNames=[GasUsed],
      ~transactionFieldNames=[Gas],
      ~stores,
    )
    let firstCounts = (
      first->countMethod("eth_getBlockByNumber"),
      first->countMethod("eth_getTransactionByHash"),
    )
    first.close()

    // A second partition over the same range, against the same stores.
    let second = await startProvider()
    let payloads = await fetchPayloads(
      ~mock=second,
      ~blockFieldNames=[GasUsed],
      ~transactionFieldNames=[Gas],
      ~stores,
    )
    let secondCounts = (
      second->countMethod("eth_getBlockByNumber"),
      second->countMethod("eth_getTransactionByHash"),
    )
    second.close()

    t.expect((firstCounts, secondCounts, payloads->Array.map(p => p.transaction))).toEqual((
      (1, 1),
      // The boundary block is still read fresh — it is this range's reorg
      // observation — but the transaction is served from the store.
      (1, 0),
      [Some({"gas": 21000n}->Obj.magic)],
    ))
  })

  Async.it("Does not re-read a field whose value came back null", async t => {
    // `to` is null on a contract creation. Judged by stored values alone the
    // row would look unfetched and be requested again on every later page.
    let stores = makeStores()
    let first = await startProvider()
    let _ = await fetchPayloads(~mock=first, ~transactionFieldNames=[To], ~stores)
    first.close()

    let second = await startProvider()
    let payloads = await fetchPayloads(~mock=second, ~transactionFieldNames=[To], ~stores)
    let reread = second->countMethod("eth_getTransactionByHash")
    second.close()

    t.expect((reread, payloads->Array.map(p => p.transaction))).toEqual((
      0,
      [Some({"to": None}->Obj.magic)],
    ))
  })
})

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
      blockStore: BlockStore.make(~ecosystem=Ecosystem.Evm, ~shouldChecksum=true),
      transactionStore: TransactionStore.make(~ecosystem=Ecosystem.Evm, ~shouldChecksum=true),
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
    "Re-grows the partition interval on the next successful query after a density shrink",
    async t => {
      let eventConfig = {...EventRegistration.evmOnEventRegistration(~id=sighash), index: 0}

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
                    ("result", echoedBlockJson(requestBody)),
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
        blockStore: BlockStore.make(~ecosystem=Ecosystem.Evm, ~shouldChecksum=false),
        transactionStore: TransactionStore.make(~ecosystem=Ecosystem.Evm, ~shouldChecksum=false),
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

  let blockJson = blockJsonAt("0x2710")

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

  // Which message maps to which interval is pinned without I/O in
  // `classify.rs`; what this exercises is that a classified message survives
  // the napi boundary as the retry the source manager acts on.
  [
    (
      "an unknown provider's suggested range",
      "query exceeds max results 20000, retry with the range 6000000-6000509",
      510,
    ),
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
          blockStore: BlockStore.make(~ecosystem=Ecosystem.Evm, ~shouldChecksum=false),
          transactionStore: TransactionStore.make(~ecosystem=Ecosystem.Evm, ~shouldChecksum=false),
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

    let blockJson = blockJsonAt("0x64")
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
      blockStore: BlockStore.make(~ecosystem=Ecosystem.Evm, ~shouldChecksum=false),
      transactionStore: TransactionStore.make(~ecosystem=Ecosystem.Evm, ~shouldChecksum=false),
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
