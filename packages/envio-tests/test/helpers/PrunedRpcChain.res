// The RpcE2eChain served by a node that only holds blocks from `baseHeight` on,
// the way some public RPCs (Sei's, for one) prune their history.
let baseHeight = 200
let height = 300

let transfers: array<RpcE2eChain.transfer> = [
  {blockNumber: 100, value: 3, logIndex: 0},
  {blockNumber: 101, value: 4, logIndex: 1},
]

let requestedBlock = (~method, ~params) => {
  let arg = params->JSON.Decode.array->Option.getOrThrow->Array.getUnsafe(0)
  switch method {
  | "eth_getLogs" =>
    Some(
      arg
      ->JSON.Decode.object
      ->Option.getOrThrow
      ->Dict.getUnsafe("fromBlock")
      ->RpcE2eChain.hexParam,
    )
  | "eth_getBlockByNumber" => Some(arg->RpcE2eChain.hexParam)
  | _ => None
  }
}

// Answers a block below the base height in Sei's own words, for each of the
// `refused` methods.
let servePruned = (~port, ~refused) =>
  MockRpcServer.start(~port, ~handler=body => {
    let request = body->JSON.parseOrThrow->JSON.Decode.object->Option.getOrThrow
    let method = request->Dict.getUnsafe("method")->JSON.Decode.string->Option.getOrThrow
    let params = request->Dict.getUnsafe("params")
    let payload = switch requestedBlock(~method, ~params) {
    | Some(blockNumber) if blockNumber < baseHeight && refused->Array.includes(method) =>
      dict{
        "error": JSON.parseOrThrow(
          `{"code":-32000,"message":"height is not available (requested height: ${blockNumber->Int.toString}, base height: ${baseHeight->Int.toString})"}`,
        ),
      }
    | _ => dict{"result": RpcE2eChain.resultFor(~transfers, ~height, ~method, ~params)}
    }
    payload->Dict.set("jsonrpc", JSON.String("2.0"))
    payload->Dict.set("id", request->Dict.getUnsafe("id"))
    (200, JSON.stringify(JSON.Object(payload)))
  })

let serveArchive = (~port) =>
  MockRpcServer.makeWithParams(~port, ~getResult=(~method, ~params) =>
    RpcE2eChain.resultFor(~transfers, ~height, ~method, ~params)
  )

let urlOf = port => `http://127.0.0.1:${port->Int.toString}`

let configYaml = (~name, ~ports) =>
  `
name: ${name}
rollback_on_reorg: false
chains:
  - id: 1337
    start_block: 100
    rpc:${ports
    ->Array.map(port =>
      `
      - url: ${port->urlOf}
        for: sync`
    )
    ->Array.join("")}
    contracts:
      - name: Token
        address: "${RpcE2eChain.contractAddress}"
        events:
          - event: Transfer(address indexed from, address indexed to, uint256 value)
`
