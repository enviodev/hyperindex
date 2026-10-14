// A page at the head spans one block, or the handful that arrived while the
// previous page was in flight, and the RPC source reads it with a single
// `eth_getLogs` across every address-bound contract rather than one per
// contract. Routing re-checks each log against its registration, so the wider
// query changes what is fetched and not what is indexed. A long page keeps the
// per-contract split, which bounds how much of a sibling's traffic a backfill
// range drags in.
//
// The server binds a fixed port because `fromUserApi` builds its config YAML
// synchronously while vitest collects, long before an async listen could report
// a random one.
let port = 18549
let url = `http://127.0.0.1:${port->Int.toString}`

let tokenAddress = "0x1111111111111111111111111111111111111111"
let vaultAddress = "0x2222222222222222222222222222222222222222"
let transferSighash = RpcE2eChain.transferSighash
let depositSighash = "0xe1fffcc4923d04b559f4d29a8bfc6cda04eb5b0d3c460751c2402c5c5cc9109c"

type emitted = {blockNumber: int, address: string, topics: array<string>, data: int, logIndex: int}

let transfer = (~blockNumber, ~value, ~logIndex) => {
  blockNumber,
  address: tokenAddress,
  topics: [
    transferSighash,
    RpcE2eChain.sender->RpcE2eChain.addressTopic,
    RpcE2eChain.recipient->RpcE2eChain.addressTopic,
  ],
  data: value,
  logIndex,
}

let deposit = (~blockNumber, ~amount, ~logIndex) => {
  blockNumber,
  address: vaultAddress,
  topics: [depositSighash, RpcE2eChain.sender->RpcE2eChain.addressTopic],
  data: amount,
  logIndex,
}

// One log per contract in the head block, and one per contract deep in the
// long range, so either page dropping a contract shows up as a missing entity.
let logs = [
  transfer(~blockNumber=100, ~value=3, ~logIndex=0),
  deposit(~blockNumber=100, ~amount=7, ~logIndex=1),
  transfer(~blockNumber=150, ~value=5, ~logIndex=0),
  deposit(~blockNumber=150, ~amount=9, ~logIndex=1),
]

let logJson = ({blockNumber, address, topics, data, logIndex}) =>
  JSON.parseOrThrow(
    `{"address":"${address}","topics":[${topics
      ->Array.map(topic => `"${topic}"`)
      ->Array.join(",")}],"data":"${data
      ->RpcE2eChain.hex
      ->RpcE2eChain.dropPrefix
      ->RpcE2eChain.padded}","blockNumber":"${blockNumber->RpcE2eChain.hex}","transactionHash":"${blockNumber->RpcE2eChain.transactionHash}","transactionIndex":"0x0","blockHash":"${blockNumber->RpcE2eChain.blockHash}","logIndex":"${logIndex->RpcE2eChain.hex}","removed":false}`,
  )

let stringsIn = json =>
  json->JSON.Decode.array->Option.getOr([])->Array.filterMap(JSON.Decode.string)

// Serves the filter the way a node does: a log is returned when its emitter is
// among the filter's addresses and its topic0 among the filter's first topic
// position.
let getLogs = (filter: dict<JSON.t>) => {
  let fromBlock = filter->Dict.getUnsafe("fromBlock")->RpcE2eChain.hexParam
  let toBlock = filter->Dict.getUnsafe("toBlock")->RpcE2eChain.hexParam
  let addresses = filter->Dict.get("address")->Option.map(stringsIn)
  let topic0s =
    filter
    ->Dict.get("topics")
    ->Option.flatMap(JSON.Decode.array)
    ->Option.flatMap(positions => positions->Array.get(0))
    ->Option.map(stringsIn)
  logs
  ->Array.filter(log =>
    log.blockNumber >= fromBlock &&
    log.blockNumber <= toBlock &&
    addresses->Option.mapOr(true, addresses => addresses->Array.includes(log.address)) &&
    topic0s->Option.mapOr(true, topic0s => topic0s->Array.includes(log.topics->Array.getUnsafe(0)))
  )
  ->Array.map(logJson)
  ->JSON.Array
}

let mock = RpcE2eChain.serveDuringSuite(() =>
  MockRpcServer.makeWithParams(~port, ~getResult=(~method, ~params) => {
    let arg = i => params->JSON.Decode.array->Option.getOrThrow->Array.getUnsafe(i)
    switch method {
    | "eth_blockNumber" => JSON.String(200->RpcE2eChain.hex)
    | "eth_getBlockByNumber" => arg(0)->RpcE2eChain.hexParam->RpcE2eChain.blockJson
    | "eth_getLogs" => arg(0)->JSON.Decode.object->Option.getOrThrow->getLogs
    | _ => JsError.throwWithMessage(`Unexpected RPC method ${method}`)
    }
  })
)

let _ = InternalTestIndexer.fromUserApi(
  ~configYaml=`
name: rpc-head-page-e2e
rollback_on_reorg: false
chains:
  - id: 1337
    start_block: 100
    rpc:
      url: ${url}
      for: sync
    contracts:
      - name: Token
        address: "${tokenAddress}"
        events:
          - event: Transfer(address indexed from, address indexed to, uint256 value)
      - name: Vault
        address: "${vaultAddress}"
        events:
          - event: Deposit(address indexed owner, uint256 amount)
`,
  ~schema=`
type Transfer {
  id: ID!
  value: BigInt!
}

type Deposit {
  id: ID!
  amount: BigInt!
}
`,
  ~handlers=`
import { indexer } from "envio";

indexer.onEvent({ contract: "Token", event: "Transfer" }, async ({ event, context }) => {
  context.Transfer.set({
    id: \`\${event.block.number}-\${event.logIndex}\`,
    value: event.params.value,
  });
});

indexer.onEvent({ contract: "Vault", event: "Deposit" }, async ({ event, context }) => {
  context.Deposit.set({
    id: \`\${event.block.number}-\${event.logIndex}\`,
    amount: event.params.amount,
  });
});
`,
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer, type Transfer, type Deposit } from "envio";

describe("Indexing a head page over RPC", () => {
  it("indexes both contracts from a one-block page and then from a long one", async (t) => {
    const indexer = createTestIndexer();

    await indexer.process({ chains: { 1337: { startBlock: 100, endBlock: 100 } } });
    await indexer.process({ chains: { 1337: { startBlock: 101, endBlock: 200 } } });

    const expected: [Transfer, Deposit, Transfer, Deposit] = [
      { id: "100-0", value: 3n },
      { id: "100-1", amount: 7n },
      { id: "150-0", value: 5n },
      { id: "150-1", amount: 9n },
    ];
    t.expect([
      await indexer.Transfer.get("100-0"),
      await indexer.Deposit.get("100-1"),
      await indexer.Transfer.get("150-0"),
      await indexer.Deposit.get("150-1"),
    ]).toEqual(expected);
  });
});
`,
)

// Each eth_getLogs as the range it asked for, the emitters it was scoped to and
// the signatures it selected, sorted so the concurrent per-contract reads of the
// long page do not make the assertion depend on completion order.
let logQueries = (mock: MockRpcServer.t) =>
  mock.requests
  ->Array.filterMap(body => {
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
      let field = name => filter->Dict.getUnsafe(name)->JSON.stringify
      Some(
        `${field("fromBlock")}-${field("toBlock")} address=${field("address")} topics=${field(
            "topics",
          )}`,
      )
    | _ => None
    }
  })
  ->Array.toSorted(String.compare)

Vitest.it("reads the one-block page with one eth_getLogs and the long page per contract", t => {
  t.expect(mock()->logQueries).toEqual([
    `"0x64"-"0x64" address=["${tokenAddress}","${vaultAddress}"] topics=[["${transferSighash}","${depositSighash}"]]`,
    `"0x65"-"0xc8" address=["${tokenAddress}"] topics=[["${transferSighash}"]]`,
    `"0x65"-"0xc8" address=["${vaultAddress}"] topics=[["${depositSighash}"]]`,
  ])
})
