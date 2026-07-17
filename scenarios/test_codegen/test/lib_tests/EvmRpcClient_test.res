open Vitest

let syncConfig = EvmChain.getSyncConfig({})

let heightCall = (~reply, ~headers=?) =>
  MockRpcServer.expectCall(
    ~method="eth_blockNumber",
    ~params=JSON.Array([]),
    ~reply,
    ~headers?,
  )

let getHeightJsonRpcError = async (client: EvmRpcClient.t): option<Rpc.rpcError> =>
  try {
    let _ = await client.getHeight()
    None
  } catch {
  | Rpc.JsonRpcError(e) => Some(e)
  }

let getHeightErrorMessage = async (client: EvmRpcClient.t) =>
  try {
    let _ = await client.getHeight()
    None
  } catch {
  | JsExn(e) => e->JsExn.message
  }

describe("EvmRpcClient - getHeight via napi", () => {
  Async.it("Parses hex result and sends a JSON-RPC request", async t => {
    let height = await MockRpcServer.withScenario(
      ~name="getHeight request contract",
      ~calls=[heightCall(~reply=RpcResult(JSON.String("0x1b4")))],
      async mock => {
        let client = EvmRpcClient.make(~url=mock.url, ~checksumAddresses=false, ~syncConfig)
        await client.getHeight()
      },
    )

    t.expect(height).toBe(436)
  })

  Async.it("Transfers JSON-RPC error as structured Rpc.JsonRpcError", async t => {
    let error = await MockRpcServer.withScenario(
      ~name="structured JSON-RPC error",
      ~calls=[
        heightCall(
          ~reply=RpcError({code: -32005, message: "limited to a 1000 blocks range"}),
        ),
      ],
      async mock => {
        let client = EvmRpcClient.make(~url=mock.url, ~checksumAddresses=false, ~syncConfig)
        await getHeightJsonRpcError(client)
      },
    )

    t.expect(error).toEqual(Some({code: -32005, message: "limited to a 1000 blocks range"}))
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
        let client = EvmRpcClient.make(~url=mock.url, ~checksumAddresses=false, ~syncConfig)
        await getHeightJsonRpcError(client)
      },
    )

    t.expect(error).toEqual(Some({code: -32029, message: "rate limited"}))
  })

  Async.it("Reports HTTP status and body snippet for a non-JSON response", async t => {
    let message = await MockRpcServer.withScenario(
      ~name="non-JSON upstream response",
      ~calls=[heightCall(~reply=RawHttp({status: 502, body: "upstream exploded"}))],
      async mock => {
        let client = EvmRpcClient.make(~url=mock.url, ~checksumAddresses=false, ~syncConfig)
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
      ~calls=[
        heightCall(~reply=RawHttp({status: 200, body: `{"jsonrpc":"2.0","id":1}`})),
      ],
      async mock => {
        let client = EvmRpcClient.make(~url=mock.url, ~checksumAddresses=false, ~syncConfig)
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
        let client = EvmRpcClient.make(~url=mock.url, ~checksumAddresses=false, ~syncConfig)
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
        let client = EvmRpcClient.make(
          ~url=mock.url,
          ~checksumAddresses=false,
          ~syncConfig,
          ~headers=Dict.fromArray([("Authorization", "Bearer test-token")]),
        )
        let height = await client.getHeight()
        t.expect(height).toBe(436)
      },
    )
  })

  it("Rejects an invalid header value at construction with a clear error", t => {
    let message = try {
      let _ = EvmRpcClient.make(
        ~url="http://127.0.0.1:1",
        ~checksumAddresses=false,
        ~syncConfig,
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
    ~params=transferParams,
  ): HyperSyncClient.Registration.input => {
    index,
    sighash: transferSighash,
    topicCount,
    eventName: "Transfer",
    contractName: "ERC20",
    isWildcard,
    dependsOnAddresses,
    startBlock: None,
    params,
    topicSelections: [
      {
        topic0: [transferSighash],
        topic1: Some([]),
        topic2: Some([]),
        topic3: Some([]),
      },
    ],
    blockFields: [],
    transactionFields: [],
  }

  let addressesByContractName = () =>
    Dict.fromArray([("ERC20", [contractAddress->Address.unsafeFromString])])

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
              `[{"address":"${contractAddress}","topics":["${transferSighash}","0x0000000000000000000000000000000000000000000000000000000000000001","0x0000000000000000000000000000000000000000000000000000000000000002"],"data":"0x00000000000000000000000000000000000000000000000000000000000003e8","blockNumber":"0x64","transactionHash":"0xabc","transactionIndex":"0x1","blockHash":"0xb64","logIndex":"0x2","removed":false}]`,
            ),
          ),
        ),
      ],
      async mock => {
        let client = EvmRpcClient.make(
          ~url=mock.url,
          ~checksumAddresses=false,
          ~syncConfig,
          ~eventRegistrations=[makeRegistration()],
        )

        let {items, toBlock} = await client.getNextPage({
          fromBlock: 100,
          toBlockCeiling: 100,
          partitionId: "0",
          registrationIndexes: [3],
          addressesByContractName: addressesByContractName(),
        })
        (
          toBlock,
          items->Array.map(({log, onEventRegistrationIndex, params}) => {
            let decoded = params->(Utils.magic: Internal.eventParams => {..})
            {
              "onEventRegistrationIndex": onEventRegistrationIndex,
              "blockNumber": log.blockNumber,
              "transactionIndex": log.transactionIndex,
              "logIndex": log.logIndex,
              "topicCount": log.topics->Array.length,
              "from": decoded["from"],
              "to": decoded["to"],
              "value": decoded["value"]->BigInt.toString,
            }
          }),
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
          "topicCount": 3,
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
              `[{"address":"${contractAddress}","topics":["0x0000000000000000000000000000000000000000000000000000000000000009"],"data":"0x","blockNumber":"0x1","transactionHash":"0xabc","transactionIndex":"0x0","blockHash":"0xb01","logIndex":"0x0","removed":false}]`,
            ),
          ),
        ),
      ],
      async mock => {
        let client = EvmRpcClient.make(
          ~url=mock.url,
          ~checksumAddresses=false,
          ~syncConfig,
          ~eventRegistrations=[makeRegistration()],
        )

        let {items} = await client.getNextPage({
          fromBlock: 1,
          toBlockCeiling: 1,
          partitionId: "0",
          registrationIndexes: [3],
          addressesByContractName: addressesByContractName(),
        })
        items->Array.length
      },
    )

    t.expect(itemCount).toEqual(0)
  })

  Async.it("Surfaces a classified provider error via the retry-decision payload", async t => {
    let exn = await MockRpcServer.withScenario(
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
        let client = EvmRpcClient.make(
          ~url=mock.url,
          ~checksumAddresses=false,
          ~syncConfig,
          ~eventRegistrations=[
            makeRegistration(
              ~index=0,
              ~topicCount=1,
              ~isWildcard=true,
              ~dependsOnAddresses=false,
              ~params=[],
            ),
          ],
        )
        try {
          let _ = await client.getNextPage({
            fromBlock: 0,
            toBlockCeiling: 5000,
            partitionId: "0",
            registrationIndexes: [0],
            addressesByContractName: Dict.make(),
          })
          None
        } catch {
        | exn => Some(exn)
        }
      },
    )

    t.expect(exn->Option.flatMap(RpcSource.getErrorMessage)).toEqual(
      Some("eth_getLogs is limited to a 1000 blocks range"),
    )
  })
})
