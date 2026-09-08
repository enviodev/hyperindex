open Vitest

let syncConfig = EvmChain.getSyncConfig({})

let makeClient = (
  ~url,
  ~headers=?,
  ~eventRegistrations=?,
  ~addressStore=?,
  ~maxConcurrentRequests=?,
  ~queryTimeoutMillis=?,
) =>
  EvmRpcClient.make(
    ~url,
    ~checksumAddresses=false,
    ~syncConfig=switch queryTimeoutMillis {
    | Some(queryTimeoutMillis) => EvmChain.getSyncConfig({queryTimeoutMillis: queryTimeoutMillis})
    | None => syncConfig
    },
    ~headers?,
    ~maxConcurrentRequests?,
    ~eventRegistrations?,
    ~addressStore=addressStore->Option.getOr(TestAddresses.makeStore()),
  )

let heightCall = (~reply, ~headers=?) =>
  MockRpcServer.expectCall(~method="eth_blockNumber", ~params=JSON.Array([]), ~reply, ~headers?)

// A failed poll carries its timing out in a structured envelope, so the
// provider's own message is read back out of it rather than off the error.
let getHeightErrorMessage = async (client: EvmRpcClient.t) =>
  try {
    let _ = await client.getHeight()
    None
  } catch {
  | exn => (exn->Source.unpackNativeRequestFailure).message
  }

// The request a failed poll made still counts towards the source's metrics,
// which is the whole reason the envelope exists rather than a plain error.
let getHeightErrorStats = async (client: EvmRpcClient.t) =>
  try {
    let _ = await client.getHeight()
    []
  } catch {
  | exn =>
    (exn->Source.unpackNativeRequestFailure).requestStats->Array.map(({Source.method: m}) => m)
  }

describe("EvmRpcClient - getHeight via napi", () => {
  Async.it("Parses hex result and sends a JSON-RPC request", async t => {
    let height = await MockRpcServer.withScenario(
      ~name="getHeight request contract",
      ~calls=[heightCall(~reply=RpcResult(JSON.String("0x1b4")))],
      async mock => {
        let client = makeClient(~url=mock.url)
        let (height, requestStats) = await client.getHeight()
        (height, requestStats->Array.map(({Source.method: method}) => method))
      },
    )

    t.expect(height).toEqual((436, ["eth_blockNumber"]))
  })

  Async.it("Reports a JSON-RPC error with its provider code", async t => {
    let error = await MockRpcServer.withScenario(
      ~name="structured JSON-RPC error",
      ~calls=[
        heightCall(~reply=RpcError({code: -32005, message: "limited to a 1000 blocks range"})),
      ],
      async mock => {
        let client = makeClient(~url=mock.url)
        await getHeightErrorMessage(client)
      },
    )

    t.expect(error).toEqual(Some("JSON-RPC error -32005: limited to a 1000 blocks range"))
  })

  Async.it("Counts the request a failed poll made", async t => {
    let methods = await MockRpcServer.withScenario(
      ~name="failed poll still counts its request",
      ~calls=[heightCall(~reply=RpcError({code: -32005, message: "boom"}))],
      async mock => {
        let client = makeClient(~url=mock.url)
        await getHeightErrorStats(client)
      },
    )

    t.expect(methods).toEqual(["eth_blockNumber"])
  })

  Async.it("Parses JSON-RPC error body even with a non-200 status", async t => {
    let error = await MockRpcServer.withScenario(
      ~name="JSON-RPC error under HTTP 429",
      ~calls=[
        heightCall(
          ~reply=RawHttp({
            status: 429,
            body: `{"jsonrpc":"2.0","id":1,"error":{"code":-32029,"message":"rate limited"}}`,
          }),
        ),
      ],
      async mock => {
        let client = makeClient(~url=mock.url)
        await getHeightErrorMessage(client)
      },
    )

    t.expect(error).toEqual(Some("JSON-RPC error -32029: rate limited"))
  })

  Async.it("Reports HTTP status and body snippet for a non-JSON response", async t => {
    let message = await MockRpcServer.withScenario(
      ~name="non-JSON upstream response",
      ~calls=[heightCall(~reply=RawHttp({status: 502, body: "upstream exploded"}))],
      async mock => {
        let client = makeClient(~url=mock.url)
        await getHeightErrorMessage(client)
      },
    )

    t.expect(message->Option.getOr("no error")).toMatch(
      /invalid JSON-RPC response for eth_blockNumber \(HTTP 502 Bad Gateway\): .+; body: upstream exploded/,
    )
  })

  Async.it("Fails when the response has neither result nor error", async t => {
    let message = await MockRpcServer.withScenario(
      ~name="missing result and error",
      ~calls=[heightCall(~reply=RawHttp({status: 200, body: `{"jsonrpc":"2.0","id":1}`}))],
      async mock => {
        let client = makeClient(~url=mock.url)
        await getHeightErrorMessage(client)
      },
    )

    t.expect(message).toEqual(
      Some("JSON-RPC response for eth_blockNumber (HTTP 200 OK) has neither result nor error"),
    )
  })

  Async.it("Fails when getHeight result is null", async t => {
    let message = await MockRpcServer.withScenario(
      ~name="null height result",
      ~calls=[heightCall(~reply=RpcResult(JSON.Null))],
      async mock => {
        let client = makeClient(~url=mock.url)
        await getHeightErrorMessage(client)
      },
    )

    t.expect(message->Option.getOr("no error")).toMatch(/parse eth_blockNumber result/)
  })

  Async.it("Sends configured custom headers with the request", async t => {
    await MockRpcServer.withScenario(
      ~name="custom RPC headers",
      ~calls=[
        heightCall(
          ~headers=Dict.fromArray([("authorization", "Bearer test-token")]),
          ~reply=RpcResult(JSON.String("0x1b4")),
        ),
      ],
      async mock => {
        let client = makeClient(
          ~url=mock.url,
          ~headers=Dict.fromArray([("Authorization", "Bearer test-token")]),
        )
        let (height, _) = await client.getHeight()
        t.expect(height).toBe(436)
      },
    )
  })

  it("Rejects an invalid header value at construction with a clear error", t => {
    let message = try {
      let _ = makeClient(
        ~url="http://127.0.0.1:1",
        ~headers=Dict.fromArray([("Authorization", "Bearer bad\nvalue")]),
      )
      None
    } catch {
    | JsExn(e) => e->JsExn.message
    }
    t.expect(message->Option.getOr("no error")).toMatch(/invalid value for RPC header/)
  })
})

describe("EvmRpcClient - getNextPage via napi", () => {
  let transferSighash = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"
  let contractAddress = "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48"
  let transferParams: array<Internal.paramMeta> = [
    {name: "from", abiType: "address", indexed: true},
    {name: "to", abiType: "address", indexed: true},
    {name: "value", abiType: "uint256", indexed: false},
  ]

  let makeRegistration = (
    ~index=3,
    ~topicCount=3,
    ~isWildcard=false,
    ~dependsOnAddresses=true,
    ~startBlock=None,
    ~params=transferParams,
    ~blockFields=[],
  ): HyperSyncClient.Registration.input => {
    index,
    sighash: transferSighash,
    topicCount,
    eventName: "Transfer",
    contractName: "ERC20",
    isWildcard,
    dependsOnAddresses,
    startBlock,
    params,
    topicSelections: [
      {
        topic0: [transferSighash],
        topic1: Some([]),
        topic2: Some([]),
        topic3: Some([]),
      },
    ],
    blockFields,
    transactionFields: [],
  }

  let blockResult = (~number, ~gasUsed="0x5208") =>
    JSON.parseOrThrow(
      `{"number":"${number}","timestamp":"0x1","gasUsed":"${gasUsed}","hash":"0x${"b1"->String.repeat(
          32,
        )}","parentHash":"0x${"b0"->String.repeat(32)}"}`,
    )

  let requestedBlock = (request: MockRpcServer.rpcRequest) =>
    request.params
    ->JSON.Decode.array
    ->Option.flatMap(params => params->Array.get(0))
    ->Option.flatMap(JSON.Decode.string)
    ->Option.getOr("0x0")

  // One log per block, so a page over the range plans one block read per log.
  let logsAcrossBlocks = (~firstBlock, ~count) =>
    Array.fromInitializer(~length=count, offset => {
      let block = (firstBlock + offset)->Int.toString(~radix=16)
      let hash = "0x" ++ offset->Int.toString->String.padStart(64, "a")
      `{"address":"${contractAddress}","topics":["${transferSighash}","0x0000000000000000000000000000000000000000000000000000000000000001","0x0000000000000000000000000000000000000000000000000000000000000002"],"data":"0x00000000000000000000000000000000000000000000000000000000000003e8","blockNumber":"0x${block}","transactionHash":"${hash}","transactionIndex":"0x1","blockHash":"0xb0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0","logIndex":"0x2","removed":false}`
    })->Array.join(",")

  // The client reads the range's last block for its reorg observation, whatever
  // the field selection is.
  let blockReply = (~number) =>
    MockRpcServer.expectCall(~method="eth_getBlockByNumber", ~reply=RpcResult(blockResult(~number)))

  let callNextPage = (client: EvmRpcClient.t, ~fromBlock, ~toBlockCeiling, ~indexes, ~addressSet) =>
    client.getNextPage(
      {
        fromBlock,
        toBlockCeiling,
        partitionId: "0",
        registrationIndexes: indexes,
        clientFilteredContracts: None,
        retry: 0,
      },
      addressSet,
      BlockStore.make(~ecosystem=Ecosystem.Evm, ~shouldChecksum=false),
      TransactionStore.make(~ecosystem=Ecosystem.Evm, ~shouldChecksum=false),
    )

  // The chain's address index, holding the one ERC20 address these logs are
  // emitted from. Non-wildcard registrations only route emitters it holds.
  let makeAddressStore = () => {
    let store = AddressStore.make(
      ~ecosystem=Ecosystem.Evm,
      ~shouldChecksum=false,
      ~contracts=[{name: "ERC20", startBlock: None, dependsOnAddresses: true}],
    )
    let _ = store->AddressStore.seedBatch([
      {
        address: contractAddress->Address.unsafeFromString,
        contractName: "ERC20",
        registrationBlock: -1,
      },
    ])
    store
  }

  Async.it("Decodes event params and parses hex log fields", async t => {
    let result = await MockRpcServer.withScenario(
      ~name="decoded getLogs page",
      ~calls=[
        MockRpcServer.expectCall(
          ~method="eth_getLogs",
          ~params=JSON.parseOrThrow(
            `[{"fromBlock":"0x64","toBlock":"0x64","topics":[["${transferSighash}"]],"address":["${contractAddress}"]}]`,
          ),
          ~reply=RpcResult(
            JSON.parseOrThrow(
              `[{"address":"${contractAddress}","topics":["${transferSighash}","0x0000000000000000000000000000000000000000000000000000000000000001","0x0000000000000000000000000000000000000000000000000000000000000002"],"data":"0x00000000000000000000000000000000000000000000000000000000000003e8","blockNumber":"0x64","transactionHash":"0xabababababababababababababababababababababababababababababababab","transactionIndex":"0x1","blockHash":"0xb0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0","logIndex":"0x2","removed":false}]`,
            ),
          ),
        ),
        blockReply(~number="0x64"),
      ],
      async mock => {
        let addressStore = makeAddressStore()
        let client = makeClient(
          ~url=mock.url,
          ~eventRegistrations=[makeRegistration()],
          ~addressStore,
        )

        let (result, _, _) = await client->callNextPage(
          ~fromBlock=100,
          ~toBlockCeiling=100,
          ~indexes=[3],
          ~addressSet=addressStore->AddressStore.makeSet(~contractName="ERC20"),
        )
        let {EvmRpcClient.items: items, toBlock} = result
        (
          toBlock,
          items->Array.map(
            ({
              blockNumber,
              transactionIndex,
              logIndex,
              srcAddress,
              onEventRegistrationIndex,
              params,
            }) => {
              let decoded = params->(Utils.magic: Internal.eventParams => {..})
              {
                "onEventRegistrationIndex": onEventRegistrationIndex,
                "blockNumber": blockNumber,
                "transactionIndex": transactionIndex,
                "logIndex": logIndex,
                "srcAddress": srcAddress->Address.toString,
                "from": decoded["from"],
                "to": decoded["to"],
                "value": decoded["value"]->BigInt.toString,
              }
            },
          ),
        )
      },
    )

    t.expect(result).toEqual((
      100,
      [
        {
          "onEventRegistrationIndex": 3,
          "blockNumber": 100,
          "transactionIndex": 1,
          "logIndex": 2,
          "srcAddress": contractAddress,
          "from": "0x0000000000000000000000000000000000000001",
          "to": "0x0000000000000000000000000000000000000002",
          "value": "1000",
        },
      ],
    ))
  })

  Async.it("Drops items when no registered signature matches", async t => {
    let itemCount = await MockRpcServer.withScenario(
      ~name="unmatched log signature",
      ~calls=[
        MockRpcServer.expectCall(
          ~method="eth_getLogs",
          ~params=JSON.parseOrThrow(
            `[{"fromBlock":"0x1","toBlock":"0x1","topics":[["${transferSighash}"]],"address":["${contractAddress}"]}]`,
          ),
          ~reply=RpcResult(
            JSON.parseOrThrow(
              `[{"address":"${contractAddress}","topics":["0x0000000000000000000000000000000000000000000000000000000000000009"],"data":"0x","blockNumber":"0x1","transactionHash":"0xabababababababababababababababababababababababababababababababab","transactionIndex":"0x0","blockHash":"0xb0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0","logIndex":"0x0","removed":false}]`,
            ),
          ),
        ),
        blockReply(~number="0x1"),
      ],
      async mock => {
        let addressStore = makeAddressStore()
        let client = makeClient(
          ~url=mock.url,
          ~eventRegistrations=[makeRegistration()],
          ~addressStore,
        )

        let ({EvmRpcClient.items: items}, _, _) = await client->callNextPage(
          ~fromBlock=1,
          ~toBlockCeiling=1,
          ~indexes=[3],
          ~addressSet=addressStore->AddressStore.makeSet(~contractName="ERC20"),
        )
        items->Array.length
      },
    )

    t.expect(itemCount).toEqual(0)
  })

  Async.it("Reports a classified provider error as a retry decision", async t => {
    // A provider's range limit comes back as a value, not an exception: the
    // narrower range to retry is the point of the call, not a failure of it.
    let outcome = await MockRpcServer.withScenario(
      ~name="classified provider range error",
      ~calls=[
        MockRpcServer.expectCall(
          ~method="eth_getLogs",
          ~params=JSON.parseOrThrow(
            `[{"fromBlock":"0x0","toBlock":"0x1388","topics":[["${transferSighash}"]]}]`,
          ),
          ~reply=RpcError({
            code: -32005,
            message: "eth_getLogs is limited to a 1000 blocks range",
          }),
        ),
      ],
      async mock => {
        let addressStore = makeAddressStore()
        let client = makeClient(
          ~url=mock.url,
          ~eventRegistrations=[
            makeRegistration(
              ~index=0,
              ~topicCount=1,
              ~isWildcard=true,
              ~dependsOnAddresses=false,
              ~params=[],
            ),
          ],
          ~addressStore,
        )
        let (result, _, _) = await client->callNextPage(
          ~fromBlock=0,
          ~toBlockCeiling=5000,
          ~indexes=[0],
          ~addressSet=addressStore->AddressStore.emptySet,
        )
        (result.kind, result.providerMessage, result.retryToBlock)
      },
    )

    t.expect(outcome).toEqual((
      "suggestedToBlock",
      Some("eth_getLogs is limited to a 1000 blocks range"),
      Some(999),
    ))
  })

  Async.it("Reads a page whose reads together outlast one request's timeout", async t => {
    // queryTimeoutMillis is documented as how long to wait before cancelling an
    // RPC request, so it bounds each read rather than the page. How long the
    // page takes follows from how many reads its logs imply, which is the one
    // thing narrowing the block range cannot fix.
    let blockCount = 5
    let queryTimeoutMillis = 400
    let firstBlock = 100

    let outcome = await MockRpcServer.withScenario(
      ~name="page outlasting a single request's timeout",
      ~calls=[
        MockRpcServer.expectCall(
          ~method="eth_getLogs",
          ~reply=RpcResult(
            JSON.parseOrThrow("[" ++ logsAcrossBlocks(~firstBlock, ~count=blockCount) ++ "]"),
          ),
        ),
        MockRpcServer.expectCall(
          ~method="eth_getBlockByNumber",
          ~times=blockCount,
          // Comfortably inside the timeout on its own; only one at a time, so
          // together they run well past it.
          ~reply=Dynamic(
            request => Delayed({
              millis: 150,
              reply: RpcResult(blockResult(~number=requestedBlock(request))),
            }),
          ),
        ),
      ],
      async mock => {
        let addressStore = makeAddressStore()
        let client = makeClient(
          ~url=mock.url,
          ~eventRegistrations=[makeRegistration(~blockFields=["GasUsed"])],
          ~addressStore,
          ~maxConcurrentRequests=1,
          ~queryTimeoutMillis,
        )

        let (result, _, _) = await client->callNextPage(
          ~fromBlock=firstBlock,
          ~toBlockCeiling=firstBlock + blockCount - 1,
          ~indexes=[3],
          ~addressSet=addressStore->AddressStore.makeSet(~contractName="ERC20"),
        )
        (result.kind, result.items->Array.length)
      },
    )

    t.expect(outcome).toEqual(("ok", blockCount))
  })

  Async.it("Backs off when one read outlasts the timeout on its own", async t => {
    let queryTimeoutMillis = 300
    let firstBlock = 100

    let outcome = await MockRpcServer.withScenario(
      ~name="single read past the request timeout",
      ~calls=[
        MockRpcServer.expectCall(
          ~method="eth_getLogs",
          ~reply=RpcResult(
            JSON.parseOrThrow("[" ++ logsAcrossBlocks(~firstBlock, ~count=1) ++ "]"),
          ),
        ),
        MockRpcServer.expectCall(
          ~method="eth_getBlockByNumber",
          ~reply=Delayed({millis: 900, reply: RpcResult(blockResult(~number="0x64"))}),
        ),
      ],
      async mock => {
        let addressStore = makeAddressStore()
        let client = makeClient(
          ~url=mock.url,
          ~eventRegistrations=[makeRegistration(~blockFields=["GasUsed"])],
          ~addressStore,
          ~queryTimeoutMillis,
        )

        let (result, _, _) = await client->callNextPage(
          ~fromBlock=firstBlock,
          ~toBlockCeiling=firstBlock,
          ~indexes=[3],
          ~addressSet=addressStore->AddressStore.makeSet(~contractName="ERC20"),
        )
        (result.kind, result.providerMessage)
      },
    )

    t.expect(outcome).toEqual((
      "backoff",
      Some(`eth_getBlockByNumber took longer than ${queryTimeoutMillis->Int.toString}ms`),
    ))
  })

  // Retried because what it observes is real concurrency: the mock releases
  // each read on its own timer, so a runner that stalls between two arrivals
  // can see a lower peak than the client actually held open.
  Async.itWithOptions(
    "Holds the block reads a page fans out to at the configured limit",
    {retry: 3},
    async t => {
    // How many requests a page makes follows from how many logs the range
    // holds, which no block interval bounds: a selection over ten blocks plans
    // ten block reads at once. The client is what keeps that burst from
    // reaching the provider all at once.
    let blockCount = 10
    let maxConcurrentRequests = 3
    let firstBlock = 100

    let inFlight = ref(0)
    let peakInFlight = ref(0)


    let peak = await MockRpcServer.withScenario(
      ~name="page block reads held at the request limit",
      ~calls=[
        MockRpcServer.expectCall(
          ~method="eth_getLogs",
          ~reply=RpcResult(
            JSON.parseOrThrow("[" ++ logsAcrossBlocks(~firstBlock, ~count=blockCount) ++ "]"),
          ),
        ),
        MockRpcServer.expectCall(
          ~method="eth_getBlockByNumber",
          ~times=blockCount,
          // Counted as the request arrives and released as its answer is
          // written, so what this observes can only lag the client's own
          // count of what it holds open - never overstate it.
          ~reply=Dynamic(
            request => {
              inFlight := inFlight.contents + 1
              peakInFlight := Pervasives.max(peakInFlight.contents, inFlight.contents)
              Delayed({
                millis: 150,
                reply: Dynamic(
                  _ => {
                    inFlight := inFlight.contents - 1
                    RpcResult(blockResult(~number=requestedBlock(request)))
                  },
                ),
              })
            },
          ),
        ),
      ],
      async mock => {
        let addressStore = makeAddressStore()
        let client = makeClient(
          ~url=mock.url,
          ~eventRegistrations=[makeRegistration(~blockFields=["GasUsed"])],
          ~addressStore,
          ~maxConcurrentRequests,
        )

        let (result, _, _) = await client->callNextPage(
          ~fromBlock=firstBlock,
          ~toBlockCeiling=firstBlock + blockCount - 1,
          ~indexes=[3],
          ~addressSet=addressStore->AddressStore.makeSet(~contractName="ERC20"),
        )
        (result.kind, result.items->Array.length, peakInFlight.contents)
      },
    )

    t.expect(peak).toEqual(("ok", blockCount, maxConcurrentRequests))
    },
  )
})
