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

type t = {hyperSync: MockHyperSyncServer.t, rpc: MockRpcServer.t}

let url = port => `http://127.0.0.1:${port->Int.toString}`

let hex = n => "0x" ++ n->Int.toString(~radix=16)
let word = body => "0x" ++ body->String.padStart(64, "0")
let dropPrefix = s => s->String.slice(~start=2, ~end=s->String.length)

// An indexed address as the topic Solidity emits for it.
let addressTopic = address => address->String.toLowerCase->dropPrefix->word
let uintTopic = n => n->BigInt.toString(~radix=16)->word

let blockHash = blockNumber => blockNumber->Int.toString(~radix=16)->word
// Every log is its own transaction, so nothing collapses two of them.
let transactionHash = ({blockNumber, logIndex}) =>
  ("a" ++ blockNumber->Int.toString(~radix=16) ++ "0" ++ logIndex->Int.toString(~radix=16))->word

let hyperSyncChain = (~logs, ~height): MockHyperSyncServer.chain => {
  blocks: Array.fromInitializer(~length=height + 1, number => JSON.Object(
    dict{
      "number": JSON.Number(number->Int.toFloat),
      "timestamp": JSON.Number(number->Int.toFloat),
      "hash": JSON.String(number->blockHash),
      "parent_hash": JSON.String((number - 1)->Pervasives.max(0)->blockHash),
    },
  )),
  transactions: logs->Array.map(log => JSON.Object(
    dict{
      "block_number": JSON.Number(log.blockNumber->Int.toFloat),
      "transaction_index": JSON.Number(log.logIndex->Int.toFloat),
      "hash": JSON.String(log->transactionHash),
    },
  )),
  logs: logs->Array.map(log => {
    let row = dict{
      "block_number": JSON.Number(log.blockNumber->Int.toFloat),
      "log_index": JSON.Number(log.logIndex->Int.toFloat),
      "transaction_index": JSON.Number(log.logIndex->Int.toFloat),
      "transaction_hash": JSON.String(log->transactionHash),
      "block_hash": JSON.String(log.blockNumber->blockHash),
      "address": JSON.String(log.address),
      "data": JSON.String(log.data->Option.getOr("0x")),
    }
    log.topics->Array.forEachWithIndex((topic, index) =>
      row->Dict.set(`topic${index->Int.toString}`, JSON.String(topic))
    )
    JSON.Object(row)
  }),
}

let rpcLog = log => JSON.Object(
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

let rpcBlock = blockNumber => JSON.Object(
  dict{
    "number": JSON.String(blockNumber->hex),
    "timestamp": JSON.String(blockNumber->hex),
    "hash": JSON.String(blockNumber->blockHash),
    "parentHash": JSON.String((blockNumber - 1)->Pervasives.max(0)->blockHash),
  },
)

// eth_getLogs' value matching: null matches anything, a list matches any of
// its members, and hex compares without regard to case.
let rpcValueMatches = (filterValue: JSON.t, actual: option<string>) =>
  switch (filterValue, actual) {
  | (JSON.Null, _) => true
  | (_, None) => false
  | (JSON.String(expected), Some(actual)) =>
    expected->String.toLowerCase === actual->String.toLowerCase
  | (JSON.Array(expected), Some(actual)) =>
    expected->Array.some(value =>
      switch value {
      | JSON.String(expected) => expected->String.toLowerCase === actual->String.toLowerCase
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

let rpcFilterMatches = (filter: dict<JSON.t>, log) => {
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

let rpcResult = (~logs, ~height, ~method, ~params) => {
  let arg = i => params->JSON.Decode.array->Option.getOrThrow->Array.getUnsafe(i)
  switch method {
  | "eth_chainId" => JSON.String("0x1")
  | "eth_blockNumber" => JSON.String(height->hex)
  | "eth_getBlockByNumber" => arg(0)->quantity->rpcBlock
  | "eth_getLogs" =>
    let filter = arg(0)->JSON.Decode.object->Option.getOrThrow
    JSON.Array(logs->Array.filter(log => rpcFilterMatches(filter, log))->Array.map(rpcLog))
  | _ => JsError.throwWithMessage(`Unexpected RPC method ${method}`)
  }
}

// Both servers for a file's whole suite. The config.yaml naming their urls is
// parsed while vitest collects, before any hook runs, so the ports are fixed
// and unique to the file.
let serveDuringSuite = (~hyperSyncPort, ~rpcPort, ~height, ~logs) => {
  let served: ref<option<t>> = ref(None)
  Vitest.Async.beforeAll(async () => {
    let hyperSync = MockHyperSyncServer.make(~height, ~port=hyperSyncPort)
    hyperSync->MockHyperSyncServer.serveChain(hyperSyncChain(~logs, ~height))
    let rpc = await MockRpcServer.makeWithParams(~port=rpcPort, ~getResult=(~method, ~params) =>
      rpcResult(~logs, ~height, ~method, ~params)
    )
    served := Some({hyperSync, rpc})
  })
  Vitest.Async.afterAll(async () =>
    switch served.contents {
    | Some({hyperSync, rpc}) =>
      hyperSync->MockHyperSyncServer.close
      await rpc.closeAsync()
    | None => ()
    }
  )
  () => served.contents->Option.getOrThrow(~message="the served chain was never started")
}

// A log filter as either source sent it: the range start, and per filter the
// addresses and the topic values at each position, lowercased and sorted so
// the assertion doesn't depend on the order a source lists them in.
type logFilter = {address: array<string>, topics: array<array<string>>}
type query = {fromBlock: int, filters: array<logFilter>}

let normalize = values => values->Array.map(String.toLowerCase)->Array.toSorted(String.compare)

let strings = json =>
  switch json {
  | JSON.String(value) => [value]
  | JSON.Array(values) => values->Array.filterMap(JSON.Decode.string)
  | _ => []
  }

let topicsOf = json =>
  switch json {
  | Some(JSON.Array(positions)) => positions->Array.map(position => position->strings->normalize)
  | _ => []
  }

// Drains the HyperSync queries received so far, oldest first.
let takeHyperSyncQueries = (served: t) =>
  served.hyperSync
  ->MockHyperSyncServer.takeQueries
  ->Array.map(query => {
    let query = query->JSON.Decode.object->Option.getOrThrow
    {
      fromBlock: query
      ->Dict.get("from_block")
      ->Option.flatMap(JSON.Decode.float)
      ->Option.getOr(0.)
      ->Float.toInt,
      filters: switch query->Dict.get("logs") {
      | Some(JSON.Array(selections)) =>
        selections->Array.map(selection => {
          let selection = selection->JSON.Decode.object->Option.getOrThrow
          {
            address: selection->Dict.get("address")->Option.mapOr([], strings)->normalize,
            topics: selection->Dict.get("topics")->topicsOf,
          }
        })
      | _ => []
      },
    }
  })

// Drains the eth_getLogs requests received so far, oldest first. RPC sends one
// filter per request, so a request reads as a query with a single filter.
let takeRpcQueries = (served: t) => {
  let requests = served.rpc.requests->Array.copy
  served.rpc.requests->Utils.Array.clearInPlace
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
        filters: [
          {
            address: filter->Dict.get("address")->Option.mapOr([], strings)->normalize,
            topics: filter->Dict.get("topics")->topicsOf,
          },
        ],
      })
    | _ => None
    }
  })
}

// Drops whatever an earlier test left on the servers, so a test reads only the
// queries its own run sent.
let reset = (served: t) => {
  let _ = served->takeHyperSyncQueries
  let _ = served->takeRpcQueries
}

// A run whose chains all name an `end_block` exits once they reach it, which is
// when everything served has been indexed. `onExit` goes to `Scenario.it`, and
// the body awaits `reachEndBlock`. One per test: a run may exit more than once,
// so a value shared with another test would already read as exited.
type endBlock = {onExit: unit => unit, reachEndBlock: unit => promise<unit>}

let endBlock = () => {
  let exited = ref(false)
  {
    onExit: () => exited := true,
    reachEndBlock: () =>
      Scenario.waitUntil(
        () => exited.contents,
        ~message="every chain to reach its end block",
        ~timeoutMs=20000.,
      ),
  }
}
