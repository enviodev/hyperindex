open Vitest

module MockJsonRpcServer = {
  type server
  type req
  type res

  @module("node:http")
  external createServer: ((req, res) => unit) => server = "createServer"
  @send external listen: (server, int, unit => unit) => unit = "listen"
  @send external closeAllConnections: server => unit = "closeAllConnections"
  @send external close: (server, unit => unit) => unit = "close"

  type address = {port: int}
  @send external address: server => address = "address"

  @send external setEncoding: (req, string) => unit = "setEncoding"
  @send external onData: (req, @as("data") _, string => unit) => unit = "on"
  @send external onEnd: (req, @as("end") _, unit => unit) => unit = "on"

  @send external writeHead: (res, int, dict<string>) => unit = "writeHead"
  @send external end_: (res, string) => unit = "end"

  type t = {
    url: string,
    requests: array<string>,
    close: unit => unit,
  }

  let make = (~status, ~body) =>
    Promise.make((resolve, _reject) => {
      let requests = []
      let server = createServer((req, res) => {
        req->setEncoding("utf8")
        let data = ref("")
        req->onData(chunk => data := data.contents ++ chunk)
        req->onEnd(() => {
          requests->Array.push(data.contents)
          res->writeHead(status, Dict.fromArray([("Content-Type", "application/json")]))
          res->end_(body)
        })
      })
      server->listen(0, () => {
        resolve({
          url: `http://127.0.0.1:${(server->address).port->Int.toString}`,
          requests,
          close: () => {
            server->closeAllConnections
            server->close(() => ())
          },
        })
      })
    })
}

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
    let mock = await MockJsonRpcServer.make(
      ~status=200,
      ~body=`{"jsonrpc":"2.0","id":1,"result":"0x1b4"}`,
    )
    let client = EvmRpcClient.make(~url=mock.url)

    let height = await client.getHeight()
    mock.close()

    t.expect((height, mock.requests->Array.map(r => r->JSON.parseOrThrow))).toEqual((
      436,
      [JSON.parseOrThrow(`{"method":"eth_blockNumber","params":[],"id":1,"jsonrpc":"2.0"}`)],
    ))
  })

  Async.it("Transfers JSON-RPC error as structured Rpc.JsonRpcError", async t => {
    let mock = await MockJsonRpcServer.make(
      ~status=200,
      ~body=`{"jsonrpc":"2.0","id":1,"error":{"code":-32005,"message":"limited to a 1000 blocks range"}}`,
    )
    let client = EvmRpcClient.make(~url=mock.url)

    let error = await getHeightJsonRpcError(client)
    mock.close()

    t.expect(error).toEqual(Some({code: -32005, message: "limited to a 1000 blocks range"}))
  })

  Async.it("Parses JSON-RPC error body even with a non-200 status", async t => {
    let mock = await MockJsonRpcServer.make(
      ~status=429,
      ~body=`{"jsonrpc":"2.0","id":1,"error":{"code":-32029,"message":"rate limited"}}`,
    )
    let client = EvmRpcClient.make(~url=mock.url)

    let error = await getHeightJsonRpcError(client)
    mock.close()

    t.expect(error).toEqual(Some({code: -32029, message: "rate limited"}))
  })

  Async.it("Reports HTTP status and body snippet for a non-JSON response", async t => {
    let mock = await MockJsonRpcServer.make(~status=502, ~body="upstream exploded")
    let client = EvmRpcClient.make(~url=mock.url)

    let message = await getHeightErrorMessage(client)
    mock.close()

    t.expect(message->Option.getOr("no error")).toMatch(
      /invalid JSON-RPC response for eth_blockNumber \(HTTP 502 Bad Gateway\): .+; body: upstream exploded/,
    )
  })

  Async.it("Fails when the response has neither result nor error", async t => {
    let mock = await MockJsonRpcServer.make(~status=200, ~body=`{"jsonrpc":"2.0","id":1}`)
    let client = EvmRpcClient.make(~url=mock.url)

    let message = await getHeightErrorMessage(client)
    mock.close()

    t.expect(message).toEqual(
      Some("JSON-RPC response for eth_blockNumber (HTTP 200 OK) has neither result nor error"),
    )
  })

  Async.it("Fails when getHeight result is null", async t => {
    let mock = await MockJsonRpcServer.make(
      ~status=200,
      ~body=`{"jsonrpc":"2.0","id":1,"result":null}`,
    )
    let client = EvmRpcClient.make(~url=mock.url)

    let message = await getHeightErrorMessage(client)
    mock.close()

    t.expect(message->Option.getOr("no error")).toMatch(/parse eth_blockNumber result/)
  })
})

describe("EvmRpcClient - getLogs via napi", () => {
  let transferSighash = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"
  let transferParams: array<Internal.paramMeta> = [
    {name: "from", abiType: "address", indexed: true},
    {name: "to", abiType: "address", indexed: true},
    {name: "value", abiType: "uint256", indexed: false},
  ]

  Async.it("Decodes event params and parses hex log fields", async t => {
    let mock = await MockJsonRpcServer.make(
      ~status=200,
      ~body=`{"jsonrpc":"2.0","id":1,"result":[{"address":"0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48","topics":["${transferSighash}","0x0000000000000000000000000000000000000000000000000000000000000001","0x0000000000000000000000000000000000000000000000000000000000000002"],"data":"0x00000000000000000000000000000000000000000000000000000000000003e8","blockNumber":"0x64","transactionHash":"0xabc","transactionIndex":"0x1","blockHash":"0xb64","logIndex":"0x2","removed":false}]}`,
    )
    let client = EvmRpcClient.make(
      ~url=mock.url,
      ~allEventParams=[
        {
          sighash: transferSighash,
          topicCount: 3,
          eventName: "Transfer",
          contractName: "ERC20",
          params: transferParams,
        },
      ],
    )

    let items = await client.getLogs({
      fromBlock: 100,
      toBlock: 100,
      topics: [Nullable.make([transferSighash])],
    })
    mock.close()

    t.expect(
      items->Array.map(({log, params}) => {
        let decoded =
          params
          ->Nullable.toOption
          ->Option.getUnsafe
          ->Dict.getUnsafe("ERC20")
          ->(Utils.magic: Internal.eventParams => {..})
        {
          "blockNumber": log.blockNumber,
          "transactionIndex": log.transactionIndex,
          "logIndex": log.logIndex,
          "topicCount": log.topics->Array.length,
          "from": decoded["from"],
          "to": decoded["to"],
          "value": decoded["value"]->BigInt.toString,
        }
      }),
    ).toEqual([
      {
        "blockNumber": 100,
        "transactionIndex": 1,
        "logIndex": 2,
        "topicCount": 3,
        "from": "0x0000000000000000000000000000000000000001",
        "to": "0x0000000000000000000000000000000000000002",
        "value": "1000",
      },
    ])
  })

  Async.it("Leaves params null when no registered signature matches", async t => {
    let mock = await MockJsonRpcServer.make(
      ~status=200,
      ~body=`{"jsonrpc":"2.0","id":1,"result":[{"address":"0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48","topics":["0x0000000000000000000000000000000000000000000000000000000000000009"],"data":"0x","blockNumber":"0x1","transactionHash":"0xabc","transactionIndex":"0x0","blockHash":"0xb01","logIndex":"0x0","removed":false}]}`,
    )
    let client = EvmRpcClient.make(
      ~url=mock.url,
      ~allEventParams=[
        {
          sighash: transferSighash,
          topicCount: 3,
          eventName: "Transfer",
          contractName: "ERC20",
          params: transferParams,
        },
      ],
    )

    let items = await client.getLogs({fromBlock: 1, toBlock: 1, topics: []})
    mock.close()

    t.expect(items->Array.map(({params}) => params->Nullable.toOption->Option.isNone)).toEqual([
      true,
    ])
  })

  Async.it("Transfers a JSON-RPC error as structured Rpc.JsonRpcError", async t => {
    let mock = await MockJsonRpcServer.make(
      ~status=200,
      ~body=`{"jsonrpc":"2.0","id":1,"error":{"code":-32005,"message":"eth_getLogs is limited to a 1000 blocks range"}}`,
    )
    let client = EvmRpcClient.make(~url=mock.url)

    let error = try {
      let _ = await client.getLogs({fromBlock: 0, toBlock: 5000, topics: []})
      None
    } catch {
    | Rpc.JsonRpcError(e) => Some(e)
    }
    mock.close()

    t.expect(error).toEqual(Some({code: -32005, message: "eth_getLogs is limited to a 1000 blocks range"}))
  })
})
