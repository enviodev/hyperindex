open Vitest
open Internal

let testApiToken =
  IndexerEnv.read().envioApiToken->Option.getOrThrow(
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

let makeSource = (
  ~url,
  ~onEventRegistrations=[],
  ~addressStore=TestAddresses.makeStore(),
  ~syncConfig: Config.sourceSyncOptions={},
  ~lowercaseAddresses=false,
  ~chainBuffer=TestChainBuffer.forChain(
    ~onEventRegistrations,
    ~addressStore,
    ~shouldChecksum=!lowercaseAddresses,
  ),
) =>
  TestSources.rpc(~url, ~syncConfig, ~maxAddressesPerRequest=IndexerEnv.read().maxPartitionSize, ~chainBuffer)

describe("RpcSource - name", () => {
  it("Returns the name of the source including sanitized rpc url", t => {
    let source = makeSource(~url="https://eth.rpc.hypersync.xyz?api_key=123")
    t.expect(source.name).toBe("RPC (eth.rpc.hypersync.xyz)")
  })
})

describe("RpcSource - getHeight", () => {
  Async.itWithOptions("Returns the current height of the chain", {retry: 3}, async t => {
    let source = makeSource(~url=`https://eth.rpc.hypersync.xyz/${testApiToken}`)
    let height = switch (await source.getHeight()).result {
    | Ok(height) => height
    | Error(failure) => JsError.throwWithMessage(failure->Source.failureMessage)
    }
    t.expect({
      "aboveLowerBound": height > 21994218,
      "belowUpperBound": height < 30000000,
    }).toEqual({
      "aboveLowerBound": true,
      "belowUpperBound": true,
    })
  })
})

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
  let fetchOutcome = async (
    ~mock: MockRpcServer.t,
    ~blockFieldNames=[],
    ~transactionFieldNames=[],
    ~lowercaseAddresses=true,
    // One buffer across calls, as one chain's partitions share it.
    ~buffer=ref(None),
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
    // The spelling is the chain's, read where the buffer builds items —
    // which is `ChainState.shouldChecksum` in production.
    let chainBuffer = switch buffer.contents {
    | Some(chainBuffer) => chainBuffer
    | None =>
      let chainBuffer = RpcSourcePins.makeBuffer(
        ~onEventRegistrations=[(registration :> Internal.onEventRegistration)],
        ~addressStore,
        ~shouldChecksum=!lowercaseAddresses,
      )
      buffer := Some(chainBuffer)
      chainBuffer
    }
    let source = makeSource(
      ~url=mock.url,
      ~onEventRegistrations=[registration],
      ~addressStore,
      ~lowercaseAddresses,
      ~chainBuffer,
    )
    let {result, requestStats} = await source.getItems(
      ~reorgableFrom=None,
      ~fromBlock=100,
      ~toBlock=Some(100),
      ~addressSet=addressStore->AddressStore.makeSet(
        ~contractName=registration.eventConfig.contractName,
      ),
      ~knownHeight=100,
      ~partitionId="0",
      ~selection={
        dependsOnAddresses: true,
        onBlockRegistrations: [],
        onTransactionRegistrations: [],
        onEventRegistrations: [(registration :> Internal.onEventRegistration)],
      },
      ~retry=0,
    )
    let result = switch result {
    | Ok({page}) =>
      let items = await page->RpcSourcePins.applyPage(
        ~buffer=chainBuffer,
        ~onEventRegistrations=[(registration :> Internal.onEventRegistration)],
      )
      Ok(
        items->Array.map(item =>
          switch item {
          | Internal.Event({payload}) =>
            let payload = payload->Evm.toPayload
            // The transaction carries the item's block, which these cases don't
            // read: they pin what the source fetches.
            payload.transaction->Option.forEach(
              transaction =>
                transaction
                ->(Utils.magic: Internal.eventTransaction => dict<unknown>)
                ->Dict.delete("block"),
            )
            payload
          | Internal.Block(_) | Internal.Transaction(_) =>
            JsError.throwWithMessage("unexpected handler item")
          }
        ),
      )
    | Error(failure) => Error(failure)
    }
    {Source.result, requestStats}
  }

  let fetchFailure = async (~mock, ~blockFieldNames=[], ~transactionFieldNames=[]) =>
    switch (await fetchOutcome(~mock, ~blockFieldNames, ~transactionFieldNames)).result {
    | Error(failure) => Some(failure)
    | Ok(_) => None
    }

  let fetchPayloads = async (
    ~mock,
    ~blockFieldNames=?,
    ~transactionFieldNames=?,
    ~lowercaseAddresses=?,
    ~buffer=?,
  ) =>
    switch (
      await fetchOutcome(
        ~mock,
        ~blockFieldNames?,
        ~transactionFieldNames?,
        ~lowercaseAddresses?,
        ~buffer?,
      )
    ).result {
    | Ok(payloads) => payloads
    | Error(failure) => JsError.throwWithMessage(failure->Source.failureMessage)
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
    let caught = switch await fetchFailure(~mock, ~transactionFieldNames=[EffectiveGasPrice]) {
    | Some(Unusable({message})) => Some(message)
    | _ => None
    }
    mock.close()
    t.expect(caught->Option.map(m => m->String.includes("effectiveGasPrice"))).toEqual(Some(true))
  })

  Async.it("Reports a selected field the provider did not return", async t => {
    let mock = await startProvider(~transaction=JSON.parseOrThrow(`{"hash":"${txHash}"}`))
    let caught = switch await fetchFailure(~mock, ~transactionFieldNames=[Gas]) {
    | Some(Unusable({message, ?blockNumber})) =>
      // The block it happened on is what makes an unservable selection
      // diagnosable, so it names the block rather than the range's end.
      Some((message->String.includes("gas"), blockNumber))
    | _ => None
    }
    mock.close()
    t.expect(caught).toEqual(Some((true, Some(100))))
  })

  // A garbled value and a response for the wrong block are both one node
  // answering badly, not a selection the chain cannot serve. Reporting them as
  // a field-selection failure disables the source for good — on a chain with a
  // single RPC the indexer then stops — so they have to stay retryable.
  // A page that ends in a retry still made its requests, and the source's
  // metrics count them — the reason both failure variants carry requestStats
  // rather than throwing them away with the page.
  Async.it("Counts the requests a failed page made", async t => {
    let mock = await startProvider(
      ~transaction=JSON.parseOrThrow(`{"hash":"${txHash}","gas":"not-hex"}`),
    )
    let methods = switch await fetchOutcome(~mock, ~transactionFieldNames=[Gas]) {
    | {result: Error(_), requestStats} =>
      let seen = Utils.Set.make()
      requestStats->Array.forEach(({Source.method: method}) => seen->Utils.Set.add(method)->ignore)
      seen->Utils.Set.toArray->Array.toSorted(String.compare)
    | {result: Ok(_)} => []
    }
    mock.close()
    t.expect(methods).toEqual(["eth_getBlockByNumber", "eth_getLogs", "eth_getTransactionByHash"])
  })

  Async.it("Retries rather than disabling the source on a value it cannot decode", async t => {
    let mock = await startProvider(
      ~transaction=JSON.parseOrThrow(`{"hash":"${txHash}","gas":"not-hex"}`),
    )
    let caught = switch await fetchFailure(~mock, ~transactionFieldNames=[Gas]) {
    | Some(Backoff({message})) => Some(message)
    | _ => None
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
    let caught = switch await fetchFailure(~mock, ~blockFieldNames=[GasUsed]) {
    | Some(Backoff({message})) => Some(message->String.includes("hash"))
    | _ => None
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
    let caught = switch await fetchFailure(~mock, ~blockFieldNames=[GasUsed]) {
    | Some(Unusable({message})) => Some(message->String.includes("gasUsed"))
    | _ => None
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
    let caught = switch await fetchFailure(~mock, ~blockFieldNames=[Timestamp]) {
    | Some(Backoff({message})) => Some(message)
    | _ => None
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

  // The reason the source consults the chain's buffer at all: partitions are
  // address slices, not range slices, so several of them scan the same blocks.
  Async.it("Does not re-read a block or transaction the buffer already covers", async t => {
    let buffer = ref(None)
    let first = await startProvider()
    let _ = await fetchPayloads(
      ~mock=first,
      ~blockFieldNames=[GasUsed],
      ~transactionFieldNames=[Gas],
      ~buffer,
    )
    let firstCounts = (
      first->countMethod("eth_getBlockByNumber"),
      first->countMethod("eth_getTransactionByHash"),
    )
    first.close()

    // A second partition over the same range, against the same buffer.
    let second = await startProvider()
    let payloads = await fetchPayloads(
      ~mock=second,
      ~blockFieldNames=[GasUsed],
      ~transactionFieldNames=[Gas],
      ~buffer,
    )
    let secondCounts = (
      second->countMethod("eth_getBlockByNumber"),
      second->countMethod("eth_getTransactionByHash"),
    )
    second.close()

    t.expect((firstCounts, secondCounts, payloads->Array.map(p => p.transaction))).toEqual((
      (1, 1),
      // The block is at the head, so it is checked and still read fresh — it
      // is this range's reorg observation — but the transaction is served
      // from the buffer.
      (1, 0),
      [Some({"gas": 21000n}->Obj.magic)],
    ))
  })

  Async.it("Does not re-read a field whose value came back null", async t => {
    // `to` is null on a contract creation. Judged by stored values alone the
    // row would look unfetched and be requested again on every later page.
    let buffer = ref(None)
    let first = await startProvider()
    let _ = await fetchPayloads(~mock=first, ~transactionFieldNames=[To], ~buffer)
    first.close()

    let second = await startProvider()
    let payloads = await fetchPayloads(~mock=second, ~transactionFieldNames=[To], ~buffer)
    let reread = second->countMethod("eth_getTransactionByHash")
    second.close()

    t.expect((reread, payloads->Array.map(p => p.transaction))).toEqual((
      0,
      [Some({"to": None}->Obj.magic)],
    ))
  })
})

describe("RpcSource - getItems on response-too-large", () => {
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
      // initialBlockInterval=ceiling=10000, backoffMultiplicative=0.8, accelerationAdditive=500
      let source = makeSource(~url=mock.url, ~onEventRegistrations=[eventConfig], ~addressStore)

      let call = async () => {
        let _ = await source.getItems(
          ~reorgableFrom=None,
          ~fromBlock=0,
          ~toBlock=Some(1_000_000),
          ~addressSet=addressStore->AddressStore.makeSet(
            ~contractName=eventConfig.eventConfig.contractName,
          ),
          ~knownHeight=1_000_000,
          ~partitionId="0",
          ~selection={
            dependsOnAddresses: true,
            onBlockRegistrations: [],
            onTransactionRegistrations: [],
            onEventRegistrations: [(eventConfig :> Internal.onEventRegistration)],
          },
          ~retry=0,
        )
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

describe("RpcSource - getItems classifies real provider block-range errors", () => {
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
  let message = "query exceeds max results 20000, retry with the range 6000000-6000509"
  let suggestedInterval = 510

  Async.it("Resizes to the interval a provider's message suggested", async t => {
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
    let source = makeSource(~url=mock.url, ~onEventRegistrations=[eventConfig], ~addressStore)

    let retry = try {
      let result = switch (
        await source.getItems(
          ~reorgableFrom=None,
          ~fromBlock=0,
          ~toBlock=Some(1_000_000),
          ~addressSet=addressStore->AddressStore.makeSet(
            ~contractName=eventConfig.eventConfig.contractName,
          ),
          ~knownHeight=1_000_000,
          ~partitionId="0",
          ~selection={
            dependsOnAddresses: true,
            onBlockRegistrations: [],
            onTransactionRegistrations: [],
            onEventRegistrations: [(eventConfig :> Internal.onEventRegistration)],
          },
          ~retry=0,
        )
      ).result {
      | Error(failure) => Some(failure)
      | Ok(_) => None
      }
      mock.close()
      result
    } catch {
    | exn =>
      mock.close()
      throw(exn)
    }

    t.expect(retry).toEqual(
      Some(Source.NarrowRange({toBlock: suggestedInterval - 1, attemptedToBlock: 9_999})),
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
    let source = makeSource(~url=mock.url, ~onEventRegistrations=allRegistrations, ~addressStore)

    let (page, filters) = try {
      let {result} = await source.getItems(
        ~reorgableFrom=None,
        ~fromBlock=0,
        ~toBlock=Some(100),
        ~addressSet=addressStore->AddressStore.makeSet(
          ~contractName=addressBound.eventConfig.contractName,
        ),
        // Far below the head, where a page's blocks aren't checked one by one.
        ~knownHeight=1_100,
        ~partitionId="selection-e2e",
        ~selection={
          dependsOnAddresses: true,
          onBlockRegistrations: [],
          onTransactionRegistrations: [],
          onEventRegistrations: selectedRegistrations->Array.map(
            reg => (reg :> Internal.onEventRegistration),
          ),
        },
        ~retry=0,
      )
      let page = switch result {
      | Ok(page) => page
      | Error(failure) => JsError.throwWithMessage(failure->Source.failureMessage)
      }
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

    // The store filters on its canonical spelling of a key, both as an
    // address and padded into a topic.
    let address = mockAddress->Address.toString->String.toLowerCase
    let addressTopic = "0x000000000000000000000000" ++ address->String.slice(~start=2)
    let expectedFilters =
      [
        `address=["${address}"];topics=[["${sighash1}"]]`,
        `address=null;topics=[["${sighash2}","${sighash3}"]]`,
        `address=null;topics=[["${sighash4}"],["${addressTopic}"]]`,
      ]->Array.toSorted(String.compare)

    t.expect((
      filters,
      page.page->TestChainBuffer.pageRowCount,
      page.latestFetchedBlockNumber,
    )).toEqual((expectedFilters, 0, 100))
  })
})

describe("RpcSource - height subscription", () => {
  let makeSource = (~url, ~ws=?, ~pollingInterval=10) =>
    TestSources.rpc(
      ~url,
      ~syncConfig={pollingInterval: pollingInterval},
      ~ws?,
      ~maxAddressesPerRequest=IndexerEnv.read().maxPartitionSize,
      ~chainBuffer=TestChainBuffer.forChain(
        ~onEventRegistrations=[],
        ~addressStore=TestAddresses.makeStore(),
      ),
    )

  it("Creates a height subscription only when a ws url is configured", t => {
    t.expect((
      makeSource(~url="https://rpc.example.test").createHeightSubscription->Option.isSome,
      makeSource(
        ~url="https://rpc.example.test",
        ~ws="wss://rpc.example.test/ws",
      ).createHeightSubscription->Option.isSome,
    )).toEqual((false, true))
  })
})
