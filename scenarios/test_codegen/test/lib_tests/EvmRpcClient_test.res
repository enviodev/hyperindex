open Vitest

let syncConfig = EvmChain.getSyncConfig({})

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
    let mock = await MockRpcServer.makeRaw(
      ~status=200,
      ~body=`{"jsonrpc":"2.0","id":1,"result":"0x1b4"}`,
    )
    let client = EvmRpcClient.make(~url=mock.url, ~checksumAddresses=false, ~syncConfig)

    let height = await client.getHeight()
    mock.close()

    t.expect((height, mock.requests->Array.map(r => r->JSON.parseOrThrow))).toEqual((
      436,
      [JSON.parseOrThrow(`{"method":"eth_blockNumber","params":[],"id":1,"jsonrpc":"2.0"}`)],
    ))
  })

  Async.it("Transfers JSON-RPC error as structured Rpc.JsonRpcError", async t => {
    let mock = await MockRpcServer.makeRaw(
      ~status=200,
      ~body=`{"jsonrpc":"2.0","id":1,"error":{"code":-32005,"message":"limited to a 1000 blocks range"}}`,
    )
    let client = EvmRpcClient.make(~url=mock.url, ~checksumAddresses=false, ~syncConfig)

    let error = await getHeightJsonRpcError(client)
    mock.close()

    t.expect(error).toEqual(Some({code: -32005, message: "limited to a 1000 blocks range"}))
  })

  Async.it("Parses JSON-RPC error body even with a non-200 status", async t => {
    let mock = await MockRpcServer.makeRaw(
      ~status=429,
      ~body=`{"jsonrpc":"2.0","id":1,"error":{"code":-32029,"message":"rate limited"}}`,
    )
    let client = EvmRpcClient.make(~url=mock.url, ~checksumAddresses=false, ~syncConfig)

    let error = await getHeightJsonRpcError(client)
    mock.close()

    t.expect(error).toEqual(Some({code: -32029, message: "rate limited"}))
  })

  Async.it("Reports HTTP status and body snippet for a non-JSON response", async t => {
    let mock = await MockRpcServer.makeRaw(~status=502, ~body="upstream exploded")
    let client = EvmRpcClient.make(~url=mock.url, ~checksumAddresses=false, ~syncConfig)

    let message = await getHeightErrorMessage(client)
    mock.close()

    t.expect(message->Option.getOr("no error")).toMatch(
      /invalid JSON-RPC response for eth_blockNumber \(HTTP 502 Bad Gateway\): .+; body: upstream exploded/,
    )
  })

  Async.it("Fails when the response has neither result nor error", async t => {
    let mock = await MockRpcServer.makeRaw(~status=200, ~body=`{"jsonrpc":"2.0","id":1}`)
    let client = EvmRpcClient.make(~url=mock.url, ~checksumAddresses=false, ~syncConfig)

    let message = await getHeightErrorMessage(client)
    mock.close()

    t.expect(message).toEqual(
      Some("JSON-RPC response for eth_blockNumber (HTTP 200 OK) has neither result nor error"),
    )
  })

  Async.it("Fails when getHeight result is null", async t => {
    let mock = await MockRpcServer.makeRaw(
      ~status=200,
      ~body=`{"jsonrpc":"2.0","id":1,"result":null}`,
    )
    let client = EvmRpcClient.make(~url=mock.url, ~checksumAddresses=false, ~syncConfig)

    let message = await getHeightErrorMessage(client)
    mock.close()

    t.expect(message->Option.getOr("no error")).toMatch(/parse eth_blockNumber result/)
  })

  Async.it("Sends configured custom headers with the request", async t => {
    let mock = await MockRpcServer.makeRaw(
      ~status=200,
      ~body=`{"jsonrpc":"2.0","id":1,"result":"0x1b4"}`,
    )
    let client = EvmRpcClient.make(
      ~url=mock.url,
      ~checksumAddresses=false,
      ~syncConfig,
      ~headers=Dict.fromArray([("Authorization", "Bearer test-token")]),
    )

    let _ = await client.getHeight()
    mock.close()

    // Node lowercases header names on the way in.
    t.expect(
      MockRpcServer.getHeader(mock.requestHeaders->Array.getUnsafe(0), "authorization"),
    ).toEqual(Some("Bearer test-token"))
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
  let transferParams: array<Internal.paramMeta> = [
    {name: "from", abiType: "address", indexed: true},
    {name: "to", abiType: "address", indexed: true},
    {name: "value", abiType: "uint256", indexed: false},
  ]

  Async.it("Decodes event params and parses hex log fields", async t => {
    let mock = await MockRpcServer.makeRaw(
      ~status=200,
      ~body=`{"jsonrpc":"2.0","id":1,"result":[{"address":"0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48","topics":["${transferSighash}","0x0000000000000000000000000000000000000000000000000000000000000001","0x0000000000000000000000000000000000000000000000000000000000000002"],"data":"0x00000000000000000000000000000000000000000000000000000000000003e8","blockNumber":"0x64","transactionHash":"0xabc","transactionIndex":"0x1","blockHash":"0xb64","logIndex":"0x2","removed":false}]}`,
    )
    let client = EvmRpcClient.make(
      ~url=mock.url,
      ~checksumAddresses=false,
      ~syncConfig,
      ~eventRegistrations=[
        {
          index: 3,
          sighash: transferSighash,
          topicCount: 3,
          eventName: "Transfer",
          contractName: "ERC20",
          isWildcard: false,
          dependsOnAddresses: true,
          params: transferParams,
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
        },
      ],
    )

    let {items, toBlock} = await client.getNextPage({
      fromBlock: 100,
      toBlockCeiling: 100,
      partitionId: "0",
      registrationIndexes: [3],
      addressesByContractName: Dict.fromArray([
        (
          "ERC20",
          ["0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48"->Address.unsafeFromString],
        ),
      ]),
    })
    // Lock down the outgoing request contract (hex block bounds + topic nesting)
    // alongside the decoded response.
    let sentRequest = mock.requests->Array.getUnsafe(0)->JSON.parseOrThrow
    mock.close()

    t.expect((
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
      sentRequest,
    )).toEqual((
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
      `{"method":"eth_getLogs","params":[{"fromBlock":"0x64","toBlock":"0x64","topics":[["${transferSighash}"]],"address":["0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48"]}],"id":1,"jsonrpc":"2.0"}`->JSON.parseOrThrow,
    ))
  })

  Async.it("Drops items when no registered signature matches", async t => {
    let mock = await MockRpcServer.makeRaw(
      ~status=200,
      ~body=`{"jsonrpc":"2.0","id":1,"result":[{"address":"0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48","topics":["0x0000000000000000000000000000000000000000000000000000000000000009"],"data":"0x","blockNumber":"0x1","transactionHash":"0xabc","transactionIndex":"0x0","blockHash":"0xb01","logIndex":"0x0","removed":false}]}`,
    )
    let client = EvmRpcClient.make(
      ~url=mock.url,
      ~checksumAddresses=false,
      ~syncConfig,
      ~eventRegistrations=[
        {
          index: 3,
          sighash: transferSighash,
          topicCount: 3,
          eventName: "Transfer",
          contractName: "ERC20",
          isWildcard: false,
          dependsOnAddresses: true,
          params: transferParams,
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
        },
      ],
    )

    let {items} = await client.getNextPage({
      fromBlock: 1,
      toBlockCeiling: 1,
      partitionId: "0",
      registrationIndexes: [3],
      addressesByContractName: Dict.fromArray([
        (
          "ERC20",
          ["0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48"->Address.unsafeFromString],
        ),
      ]),
    })
    mock.close()

    t.expect(items->Array.length).toEqual(0)
  })

  Async.it("Surfaces a classified provider error via the retry-decision payload", async t => {
    let mock = await MockRpcServer.makeRaw(
      ~status=200,
      ~body=`{"jsonrpc":"2.0","id":1,"error":{"code":-32005,"message":"eth_getLogs is limited to a 1000 blocks range"}}`,
    )
    let client = EvmRpcClient.make(
      ~url=mock.url,
      ~checksumAddresses=false,
      ~syncConfig,
      ~eventRegistrations=[
        {
          index: 0,
          sighash: transferSighash,
          topicCount: 1,
          eventName: "Transfer",
          contractName: "ERC20",
          isWildcard: true,
          dependsOnAddresses: false,
          params: [],
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
        },
      ],
    )

    let exn = try {
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
    mock.close()

    t.expect(exn->Option.flatMap(RpcSource.getErrorMessage)).toEqual(
      Some("eth_getLogs is limited to a 1000 blocks range"),
    )
  })
})
