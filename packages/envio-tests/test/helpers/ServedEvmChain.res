// One EVM chain's logs, served by a real local HyperSync server and a real
// local JSON-RPC server at once, so a config.yaml can point a chain at either
// and the whole indexer loop — query building, the request, decoding, routing —
// runs as it would against a provider. Both servers answer a query with the
// logs its filter matches, the way a provider does, so a filter the source
// failed to send shows up as rows the indexer should never have written.

type log = {
  blockNumber: int,
  logIndex: int,
  address: string,
  topics: array<string>,
  data?: string,
}

// A transaction both servers hold. A log's transaction is the one at its log
// index, so a log and a transaction sharing a block and index share a hash.
type transaction = {
  blockNumber: int,
  transactionIndex: int,
  from: string,
  // Absent for a contract creation.
  to?: string,
  // Calldata; defaults to empty.
  input?: string,
  // Hex quantity; defaults to zero.
  value?: string,
  // 1 succeeded (the default), 0 reverted.
  status?: int,
}

type servers = {hyperSync: MockHyperSyncServer.t, rpc: MockRpcServer.t}

// The config.yaml naming the servers' urls is parsed while vitest collects,
// before any hook runs, so the ports are fixed and unique to the file.
type t = {
  hyperSyncPort: int,
  rpcPort: int,
  height: int,
  mutable servers: option<servers>,
}

let url = port => `http://127.0.0.1:${port->Int.toString}`

let hex = n => "0x" ++ n->Int.toString(~radix=16)
let word = body => "0x" ++ body->String.padStart(64, "0")
let dropPrefix = s => s->String.slice(~start=2, ~end=s->String.length)

// An indexed address as the topic Solidity emits for it.
let addressTopic = address => address->String.toLowerCase->dropPrefix->word
let uintTopic = n => n->BigInt.toString(~radix=16)->word

let blockHash = blockNumber => blockNumber->Int.toString(~radix=16)->word
// Every log is its own transaction, so nothing collapses two of them.
let transactionHashAt = (~blockNumber, ~transactionIndex) =>
  ("a" ++ blockNumber->Int.toString(~radix=16) ++ "0" ++ transactionIndex->Int.toString(~radix=16))
    ->word
let transactionHash = ({blockNumber, logIndex}: log) =>
  transactionHashAt(~blockNumber, ~transactionIndex=logIndex)

let transactionStatus = (tx: transaction) => tx.status->Option.getOr(1)
let transactionInput = (tx: transaction) => tx.input->Option.getOr("0x")
let transactionValue = (tx: transaction) => tx.value->Option.getOr("0x0")
let gasUsed = 21_000

let hyperSyncChain = (~logs, ~transactions, ~height): MockHyperSyncServer.chain => {
  blocks: Array.fromInitializer(~length=height + 1, number => JSON.Object(
    dict{
      "number": JSON.Number(number->Int.toFloat),
      "timestamp": JSON.Number(number->Int.toFloat),
      "hash": JSON.String(number->blockHash),
    },
  )),
  logs: logs->Array.map((log: log) => {
    let row = dict{
      "block_number": JSON.Number(log.blockNumber->Int.toFloat),
      "log_index": JSON.Number(log.logIndex->Int.toFloat),
      "transaction_index": JSON.Number(log.logIndex->Int.toFloat),
      "address": JSON.String(log.address),
      "data": JSON.String(log.data->Option.getOr("0x")),
    }
    log.topics->Array.forEachWithIndex((topic, index) =>
      row->Dict.set(`topic${index->Int.toString}`, JSON.String(topic))
    )
    JSON.Object(row)
  }),
  transactions: transactions->Array.map((tx: transaction) => {
    let row = dict{
      "block_number": JSON.Number(tx.blockNumber->Int.toFloat),
      "transaction_index": JSON.Number(tx.transactionIndex->Int.toFloat),
      "hash": JSON.String(
        transactionHashAt(~blockNumber=tx.blockNumber, ~transactionIndex=tx.transactionIndex),
      ),
      "from": JSON.String(tx.from),
      "input": JSON.String(tx->transactionInput),
      "value": JSON.String(tx->transactionValue),
      "status": JSON.Number(tx->transactionStatus->Int.toFloat),
      "gas_used": JSON.Number(gasUsed->Int.toFloat),
      "nonce": JSON.Number(0.),
      "gas": JSON.Number(gasUsed->Int.toFloat),
      "cumulative_gas_used": JSON.Number(gasUsed->Int.toFloat),
      "effective_gas_price": JSON.Number(1.),
      "logs_bloom": JSON.String("0x" ++ "00"->String.repeat(256)),
    }
    switch tx.to {
    | Some(to) => row->Dict.set("to", JSON.String(to))
    | None => ()
    }
    JSON.Object(row)
  }),
}

let rpcLog = (log: log) => JSON.Object(
  dict{
    "address": JSON.String(log.address),
    "topics": JSON.Array(log.topics->Array.map(topic => JSON.String(topic))),
    "data": JSON.String(log.data->Option.getOr("0x")),
    "blockNumber": JSON.String(log.blockNumber->hex),
    "blockHash": JSON.String(log.blockNumber->blockHash),
    "transactionHash": JSON.String(log->transactionHash),
    "transactionIndex": JSON.String(log.logIndex->hex),
    "logIndex": JSON.String(log.logIndex->hex),
    "removed": JSON.Boolean(false),
  },
)

let rpcTransaction = (tx: transaction) => JSON.Object(
  dict{
    "hash": JSON.String(
      transactionHashAt(~blockNumber=tx.blockNumber, ~transactionIndex=tx.transactionIndex),
    ),
    "blockNumber": JSON.String(tx.blockNumber->hex),
    "blockHash": JSON.String(tx.blockNumber->blockHash),
    "transactionIndex": JSON.String(tx.transactionIndex->hex),
    "from": JSON.String(tx.from),
    "to": switch tx.to {
    | Some(to) => JSON.String(to)
    | None => JSON.Null
    },
    "input": JSON.String(tx->transactionInput),
    "value": JSON.String(tx->transactionValue),
    "nonce": JSON.String("0x0"),
    "gas": JSON.String(gasUsed->hex),
    "gasPrice": JSON.String("0x1"),
    "type": JSON.String("0x2"),
  },
)

let rpcReceipt = (tx: transaction) => JSON.Object(
  dict{
    "transactionHash": JSON.String(
      transactionHashAt(~blockNumber=tx.blockNumber, ~transactionIndex=tx.transactionIndex),
    ),
    "blockNumber": JSON.String(tx.blockNumber->hex),
    "blockHash": JSON.String(tx.blockNumber->blockHash),
    "transactionIndex": JSON.String(tx.transactionIndex->hex),
    "from": JSON.String(tx.from),
    "to": switch tx.to {
    | Some(to) => JSON.String(to)
    | None => JSON.Null
    },
    "status": JSON.String(tx->transactionStatus->hex),
    "gasUsed": JSON.String(gasUsed->hex),
    "cumulativeGasUsed": JSON.String(gasUsed->hex),
    "effectiveGasPrice": JSON.String("0x1"),
    "logsBloom": JSON.String("0x" ++ "00"->String.repeat(256)),
    "type": JSON.String("0x2"),
  },
)

let rpcBlock = (blockNumber, ~transactions=[], ~fullTransactions=false) => JSON.Object(
  dict{
    "number": JSON.String(blockNumber->hex),
    "timestamp": JSON.String(blockNumber->hex),
    "hash": JSON.String(blockNumber->blockHash),
    "parentHash": JSON.String((blockNumber - 1)->Pervasives.max(0)->blockHash),
    "transactions": JSON.Array(
      transactions
      ->Array.filter((tx: transaction) => tx.blockNumber === blockNumber)
      ->Array.map(tx =>
        fullTransactions
          ? rpcTransaction(tx)
          : JSON.String(
              transactionHashAt(~blockNumber=tx.blockNumber, ~transactionIndex=tx.transactionIndex),
            )
      ),
    ),
  },
)

let sameHex = (a, b) => a->String.toLowerCase === b->String.toLowerCase

// eth_getLogs' value matching: null matches anything, a list matches any of
// its members, and hex compares without regard to case.
let rpcValueMatches = (filterValue: JSON.t, actual: option<string>) =>
  switch (filterValue, actual) {
  | (JSON.Null, _) => true
  | (_, None) => false
  | (JSON.String(expected), Some(actual)) => sameHex(expected, actual)
  | (JSON.Array(expected), Some(actual)) =>
    expected->Array.some(value =>
      switch value {
      | JSON.String(expected) => sameHex(expected, actual)
      | _ => false
      }
    )
  | _ => false
  }

let quantity = json =>
  json
  ->JSON.Decode.string
  ->Option.flatMap(s => s->dropPrefix->Int.fromString(~radix=16))
  ->Option.getOrThrow(~message="expected a hex quantity")

let rpcFilterMatches = (filter: dict<JSON.t>, log: log) => {
  let inRange =
    log.blockNumber >= filter->Dict.getUnsafe("fromBlock")->quantity &&
      log.blockNumber <= filter->Dict.getUnsafe("toBlock")->quantity
  let addressMatches = switch filter->Dict.get("address") {
  | None => true
  | Some(value) => rpcValueMatches(value, Some(log.address))
  }
  let topicsMatch = switch filter->Dict.get("topics") {
  | None => true
  | Some(JSON.Array(constraints)) =>
    constraints->Array.everyWithIndex((value, index) =>
      rpcValueMatches(value, log.topics->Array.get(index))
    )
  | Some(_) => false
  }
  inRange && addressMatches && topicsMatch
}

let rpcResult = (~logs, ~transactions, ~height, ~method, ~params) => {
  let arg = i => params->JSON.Decode.array->Option.getOrThrow->Array.getUnsafe(i)
  let byHash = () => {
    let hash = arg(0)->JSON.Decode.string->Option.getOrThrow->String.toLowerCase
    transactions->Array.find((tx: transaction) =>
      transactionHashAt(~blockNumber=tx.blockNumber, ~transactionIndex=tx.transactionIndex) === hash
    )
  }
  switch method {
  | "eth_chainId" => JSON.String("0x1")
  | "eth_blockNumber" => JSON.String(height->hex)
  | "eth_getBlockByNumber" =>
    arg(0)->quantity->rpcBlock(~transactions, ~fullTransactions=arg(1) === JSON.Boolean(true))
  | "eth_getTransactionByHash" => byHash()->Option.mapOr(JSON.Null, rpcTransaction)
  | "eth_getTransactionReceipt" => byHash()->Option.mapOr(JSON.Null, rpcReceipt)
  | "eth_getLogs" =>
    let filter = arg(0)->JSON.Decode.object->Option.getOrThrow
    JSON.Array(logs->Array.filter(log => rpcFilterMatches(filter, log))->Array.map(rpcLog))
  | _ => JsError.throwWithMessage(`Unexpected RPC method ${method}`)
  }
}

// Both servers, for a file's whole suite.
let serveDuringSuite = (~hyperSyncPort, ~rpcPort, ~height, ~logs, ~transactions=[]) => {
  let served = {hyperSyncPort, rpcPort, height, servers: None}
  Vitest.Async.beforeAll(async () => {
    let hyperSync = MockHyperSyncServer.make(~height, ~port=hyperSyncPort)
    hyperSync->MockHyperSyncServer.serveChain(hyperSyncChain(~logs, ~transactions, ~height))
    let rpc = await MockRpcServer.makeWithParams(~port=rpcPort, ~getResult=(~method, ~params) =>
      rpcResult(~logs, ~transactions, ~height, ~method, ~params)
    )
    served.servers = Some({hyperSync, rpc})
  })
  Vitest.Async.afterAll(async () =>
    switch served.servers {
    | Some({hyperSync, rpc}) =>
      hyperSync->MockHyperSyncServer.close
      await rpc.closeAsync()
    | None => ()
    }
  )
  served
}

let servers = served =>
  served.servers->Option.getOrThrow(~message="the served chain was never started")

// config.yaml `chains:` entries fetching from the served HyperSync or RPC
// server, each stopping at the served height. `contracts` is the `contracts:`
// list every chain gets, indented to sit under it.
let chainsYaml = (served, ~hyperSync, ~rpc, ~contracts) => {
  let chain = (id, source) =>
    `
  - id: ${id->Int.toString}
    start_block: 1
    end_block: ${served.height->Int.toString}${source}
    contracts:${contracts}`
  Array.concat(
    hyperSync->Array.map(id =>
      chain(
        id,
        `
    hypersync_config:
      url: ${url(served.hyperSyncPort)}`,
      )
    ),
    rpc->Array.map(id =>
      chain(
        id,
        `
    rpc:
      url: ${url(served.rpcPort)}
      for: sync`,
      )
    ),
  )->Array.join("")
}

// A log filter as either source sent it: the range start, and per filter the
// addresses and the topic values at each position, lowercased and sorted so
// the assertion doesn't depend on the order a source lists them in.
type logFilter = {address: array<string>, topics: array<array<string>>}
// A transaction filter as HyperSync received it, lowercased and sorted like
// the log filters.
type transactionFilter = {
  from: array<string>,
  to: array<string>,
  sighash: array<string>,
  status: option<int>,
}
type query = {
  fromBlock: int,
  filters: array<logFilter>,
  transactionFilters: array<transactionFilter>,
}

let normalize = values => values->Array.map(String.toLowerCase)->Array.toSorted(String.compare)

let strings = json =>
  switch json {
  | JSON.String(value) => [value]
  | JSON.Array(values) => values->Array.filterMap(JSON.Decode.string)
  | _ => []
  }

let logFilter = (filter: dict<JSON.t>) => {
  address: filter->Dict.get("address")->Option.mapOr([], strings)->normalize,
  topics: switch filter->Dict.get("topics") {
  | Some(JSON.Array(positions)) => positions->Array.map(position => position->strings->normalize)
  | _ => []
  },
}

let transactionFilter = (filter: dict<JSON.t>) => {
  from: filter->Dict.get("from")->Option.mapOr([], strings)->normalize,
  to: filter->Dict.get("to")->Option.mapOr([], strings)->normalize,
  sighash: filter->Dict.get("sighash")->Option.mapOr([], strings)->normalize,
  status: filter->Dict.get("status")->Option.flatMap(JSON.Decode.float)->Option.map(Float.toInt),
}

let selections = (query: dict<JSON.t>, table, parse) =>
  switch query->Dict.get(table) {
  | Some(JSON.Array(selections)) =>
    selections->Array.map(selection => selection->JSON.Decode.object->Option.getOrThrow->parse)
  | _ => []
  }

// Drains the HyperSync queries received so far, oldest first.
let takeHyperSyncQueries = served =>
  (served->servers).hyperSync
  ->MockHyperSyncServer.takeQueries
  ->Array.map(query => {
    let query = query->JSON.Decode.object->Option.getOrThrow
    {
      fromBlock: query
      ->Dict.get("from_block")
      ->Option.flatMap(JSON.Decode.float)
      ->Option.getOr(0.)
      ->Float.toInt,
      filters: query->selections("logs", logFilter),
      transactionFilters: query->selections("transactions", transactionFilter),
    }
  })

// The JSON-RPC methods requested so far with their params, oldest first,
// without draining them.
type rpcRequest = {method: string, params: array<JSON.t>}

let rpcRequests = (served): array<rpcRequest> =>
  (served->servers).rpc.requests->Array.map(body => {
    let request = body->JSON.parseOrThrow->JSON.Decode.object->Option.getOrThrow
    {
      method: request->Dict.get("method")->Option.flatMap(JSON.Decode.string)->Option.getOr(""),
      params: request->Dict.get("params")->Option.flatMap(JSON.Decode.array)->Option.getOr([]),
    }
  })

// Drains the eth_getLogs requests received so far, oldest first. RPC sends one
// filter per request, so a request reads as a query with a single filter.
let takeRpcQueries = served => {
  let {rpc} = served->servers
  let requests = rpc.requests->Array.copy
  rpc.requests->Utils.Array.clearInPlace
  requests->Array.filterMap(body => {
    let request = body->JSON.parseOrThrow->JSON.Decode.object->Option.getOrThrow
    switch request->Dict.get("method") {
    | Some(JSON.String("eth_getLogs")) =>
      let filter =
        request
        ->Dict.getUnsafe("params")
        ->JSON.Decode.array
        ->Option.getOrThrow
        ->Array.getUnsafe(0)
        ->JSON.Decode.object
        ->Option.getOrThrow
      Some({
        fromBlock: filter->Dict.getUnsafe("fromBlock")->quantity,
        filters: [filter->logFilter],
        transactionFilters: [],
      })
    | _ => None
    }
  })
}

// Runs `scenario` until every chain reaches its `end_block`, which is when
// everything served has been indexed, then `body`. The queries an earlier run
// left on the servers are dropped first, so `body` reads only this run's.
let run = async (served, scenario, ~clientFilterAddressThreshold=?, body) => {
  let _ = served->takeHyperSyncQueries
  let _ = served->takeRpcQueries
  let exited = ref(false)
  await scenario->Scenario.run(
    ~yamlSources=true,
    ~clientFilterAddressThreshold?,
    ~onExit=() => exited := true,
    async (~indexer, ~source as _) => {
      await Scenario.waitUntil(
        () => exited.contents,
        ~message="every chain to reach its end block",
        ~timeoutMs=20000.,
      )
      await body(indexer)
    },
  )
}

// Each handler writes one Routed row per log it is given, keyed by the log and
// a name for the handler, so the rows say which handler saw which log.
let routedSchema = `
type Routed {
  id: ID!
}
`

let routedHandlers = `
import { indexer } from "envio";

type Routable = { chainId: number; block: { number: number }; logIndex: number };
const routed = (event: Routable, name: string) => ({
  id: \`\${event.chainId}-\${event.block.number}-\${event.logIndex}-\${name}\`,
});
`

let routed = (~chainId, ~blockNumber, ~logIndex=0, name) =>
  `${chainId->Int.toString}-${blockNumber->Int.toString}-${logIndex->Int.toString}-${name}`

let sorted = ids => ids->Array.toSorted(String.compare)

type routedRow = {id: string}

let readRouted = async (indexer: IndexerRunner.t) => {
  let rows: array<routedRow> = await indexer.query("Routed")
  rows->Array.map(row => row.id)->sorted
}
