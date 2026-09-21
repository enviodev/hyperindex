// A tiny EVM chain served over JSON-RPC, for tests that run the whole indexer
// loop against a real HTTP server rather than a mocked source. It synthesizes
// just enough of `eth_getLogs`, `eth_getBlockByNumber` and `eth_blockNumber`
// for the RPC source to page a range and observe its block hashes.

let contractAddress = "0x1111111111111111111111111111111111111111"
let transferSighash = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"

let sender = Envio.TestHelpers.Addresses.mockAddresses->Array.getUnsafe(2)
let recipient = Envio.TestHelpers.Addresses.mockAddresses->Array.getUnsafe(1)

let hex = n => "0x" ++ n->Int.toString(~radix=16)
let dropPrefix = s => s->String.slice(~start=2, ~end=s->String.length)
let padded = body => "0x" ++ body->String.padStart(64, "0")
let addressTopic = address => address->Address.toString->dropPrefix->padded

let blockHash = blockNumber => blockNumber->hex->dropPrefix->padded

// Distinct per block, and distinct from that block's hash, so nothing collapses
// two transfers into one.
let transactionHash = blockNumber => ("a" ++ blockNumber->Int.toString(~radix=16))->padded

// A transfer of `value` at `logIndex` in `blockNumber`.
type transfer = {blockNumber: int, value: int, logIndex: int}

let blockJson = blockNumber =>
  JSON.parseOrThrow(
    `{"number":"${blockNumber->hex}","timestamp":"${blockNumber->hex}","hash":"${blockNumber->blockHash}","parentHash":"${(blockNumber - 1)
        ->blockHash}"}`,
  )

let logJson = ({blockNumber, value, logIndex}) =>
  JSON.parseOrThrow(
    `{"address":"${contractAddress}","topics":["${transferSighash}","${sender->addressTopic}","${recipient->addressTopic}"],"data":"${value
      ->hex
      ->dropPrefix
      ->padded}","blockNumber":"${blockNumber->hex}","transactionHash":"${blockNumber->transactionHash}","transactionIndex":"0x0","blockHash":"${blockNumber->blockHash}","logIndex":"${logIndex->hex}","removed":false}`,
  )

let hexParam = json => {
  let quantity = json->JSON.Decode.string->Option.getOrThrow(~message="expected a hex quantity")
  quantity
  ->dropPrefix
  ->Int.fromString(~radix=16)
  ->Option.getOrThrow(~message="expected a parsable hex quantity")
}

// The `result` this chain answers a JSON-RPC method with.
let resultFor = (~transfers, ~height, ~method, ~params) => {
  let arg = i => params->JSON.Decode.array->Option.getOrThrow->Array.getUnsafe(i)
  switch method {
  | "eth_blockNumber" => JSON.String(height->hex)
  | "eth_getBlockByNumber" => arg(0)->hexParam->blockJson
  | "eth_getLogs" =>
    let filter = arg(0)->JSON.Decode.object->Option.getOrThrow
    let fromBlock = filter->Dict.getUnsafe("fromBlock")->hexParam
    let toBlock = filter->Dict.getUnsafe("toBlock")->hexParam
    JSON.Array(
      transfers
      ->Array.filter(({blockNumber}) => blockNumber >= fromBlock && blockNumber <= toBlock)
      ->Array.map(logJson),
    )
  | _ => JsError.throwWithMessage(`Unexpected RPC method ${method}`)
  }
}

// The schema and handler source both files share: one entity per log, keyed by
// the log's own coordinates, so a dropped log shows up as a missing entity
// rather than a wrong total.
let schema = `
type Transfer {
  id: ID!
  to: String!
  value: BigInt!
}
`

let handlers = `
import { indexer } from "envio";

indexer.onEvent({ contract: "Token", event: "Transfer" }, async ({ event, context }) => {
  context.Transfer.set({
    id: \`\${event.block.number}-\${event.logIndex}\`,
    to: event.params.to,
    value: event.params.value,
  });
});
`

// `blockJson` above serves only the fields the reorg check needs, so any
// `fieldSelection` naming a block field is a field the provider will not return.
let configYaml = (~name, ~url, ~extraRpc="", ~fieldSelection="") =>
  `
name: ${name}
rollback_on_reorg: false${fieldSelection}
chains:
  - id: 1337
    start_block: 100
    rpc:
      url: ${url}
      for: sync${extraRpc}
    contracts:
      - name: Token
        address: "${contractAddress}"
        events:
          - event: Transfer(address indexed from, address indexed to, uint256 value)
`

// The wire traffic a test asserts on: each request as its method, with an
// eth_getLogs carrying the range it asked for, sorted so concurrent block reads
// do not make the assertion depend on completion order.
let callSummary = (mock: MockRpcServer.t) =>
  mock.requests
  ->Array.map(body => {
    let request = body->JSON.parseOrThrow->JSON.Decode.object->Option.getOrThrow
    let method = request->Dict.getUnsafe("method")->JSON.Decode.string->Option.getOrThrow
    switch method {
    | "eth_getLogs" =>
      let filter =
        request
        ->Dict.getUnsafe("params")
        ->JSON.Decode.array
        ->Option.getOrThrow
        ->Array.getUnsafe(0)
        ->JSON.Decode.object
        ->Option.getOrThrow
      `eth_getLogs ${filter->Dict.getUnsafe("fromBlock")->JSON.stringify}-${filter
        ->Dict.getUnsafe("toBlock")
        ->JSON.stringify}`
    | _ => method
    }
  })
  ->Array.toSorted(String.compare)

// The eth_getLogs ranges in the order they were asked for. Pages are sequential,
// so unlike the concurrent block reads their order is meaningful: it shows how a
// failed page narrows the ones that follow it.
let logRanges = (mock: MockRpcServer.t) =>
  mock.requests->Array.filterMap(body => {
    let request = body->JSON.parseOrThrow->JSON.Decode.object->Option.getOrThrow
    switch request->Dict.getUnsafe("method")->JSON.Decode.string {
    | Some("eth_getLogs") =>
      let filter =
        request
        ->Dict.getUnsafe("params")
        ->JSON.Decode.array
        ->Option.getOrThrow
        ->Array.getUnsafe(0)
        ->JSON.Decode.object
        ->Option.getOrThrow
      let field = name =>
        filter->Dict.getUnsafe(name)->JSON.Decode.string->Option.getOrThrow
      Some(`${field("fromBlock")}-${field("toBlock")}`)
    | _ => None
    }
  })
