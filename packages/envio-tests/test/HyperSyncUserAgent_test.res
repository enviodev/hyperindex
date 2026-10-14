open Vitest

// Each ecosystem's client sends its own requests from inside the native addon,
// and the height stream goes out through `fetch`, so a local server is the only
// place to see what every one of them actually says it is.

let storage: UserAgent.storage = {postgres: true, clickhouse: true}

let expected = ecosystem => Some(
  UserAgent.format(
    ~version=Utils.EnvioPackage.value.version,
    {...UserAgent.currentHost()->UserAgent.hostFacts, ecosystem, storage},
  ),
)

let unique = values =>
  values->Array.filterWithIndex((value, i) => values->Array.indexOf(value) === i)

// Answers every request with `respond` and returns the distinct user agents
// the requests made by `run` carried.
let userAgentsSeen = async (~respond, run) => {
  let userAgents = []
  let server = MockRpcServer.createServer((req, res) => {
    userAgents
    ->Array.push(req->MockRpcServer.reqHeaders->MockRpcServer.getHeader("user-agent"))
    ->ignore
    respond(res)
  })
  let url = await Promise.make((resolve, _reject) =>
    server->MockRpcServer.listenOnHost(0, "127.0.0.1", () =>
      resolve(`http://127.0.0.1:${(server->MockRpcServer.address).port->Int.toString}`)
    )
  )
  await run(url)
  server->MockRpcServer.closeAllConnections
  await Promise.make((resolve, _reject) => server->MockRpcServer.close(() => resolve()))
  userAgents->unique
}

let reply = (res, ~contentType, body) => {
  res->MockRpcServer.writeHead(200, dict{"Content-Type": contentType})
  res->MockRpcServer.end_(body)
}

let addressStore = ecosystem => AddressStore.make(~ecosystem, ~contracts=[])

let evmSource = url =>
  EvmHyperSyncSource.make({
    chainId: 1->ChainId.fromInt,
    endpointUrl: url,
    onEventRegistrations: [],
    apiToken: Some(MockHyperSyncServer.apiToken),
    clientTimeoutMillis: 10_000,
    lowercaseAddresses: true,
    serializationFormat: Json,
    enableQueryCaching: false,
    logLevel: #error,
    addressStore: addressStore(Evm),
  })

describe("A HyperSync source", () => {
  Async.it("tells HyperSync what the indexer runs on", async t => {
    UserAgent.prime(~ecosystem=Evm, ~storage)
    let evmHeight = await userAgentsSeen(
      ~respond=res => res->reply(~contentType="application/json", `{"height":100}`),
      async url => {
        let _ = await evmSource(url).getHeightOrThrow()
      },
    )
    let evmHeightStream = await userAgentsSeen(
      ~respond=res => {
        res->MockRpcServer.writeHead(200, dict{"Content-Type": "text/event-stream"})
        res->MockRpcServer.write("event: height\ndata: 100\n\n")
      },
      async url => {
        let heights = []
        let unsubscribe = (evmSource(url).createHeightSubscription->Option.getOrThrow)(
          ~onHeight=height => heights->Array.push(height)->ignore,
          ~onStatus=_ => (),
        )
        await Scenario.waitUntil(() => heights->Array.length > 0, ~message="the height stream")
        unsubscribe()
      },
    )

    UserAgent.prime(~ecosystem=Fuel, ~storage)
    let fuelHeight = await userAgentsSeen(
      ~respond=res => res->reply(~contentType="application/json", `{"height":100}`),
      async url => {
        let source = FuelHyperSyncSource.make({
          chainId: 0->ChainId.fromInt,
          endpointUrl: url,
          apiToken: Some(MockHyperSyncServer.apiToken),
          onEventRegistrations: [],
          addressStore: addressStore(Fuel),
        })
        let _ = await source.getHeightOrThrow()
      },
    )

    UserAgent.prime(~ecosystem=Svm, ~storage)
    let svmHeight = await userAgentsSeen(
      ~respond=res => res->reply(~contentType="text/plain", "100"),
      async url => {
        let source = SvmHyperSyncSource.make({
          chainId: 0->ChainId.fromInt,
          endpointUrl: url,
          apiToken: Some(MockHyperSyncServer.apiToken),
          onEventRegistrations: [],
          clientTimeoutMillis: 10_000,
          addressStore: addressStore(Svm),
        })
        let _ = await source.getHeightOrThrow()
      },
    )

    t.expect([evmHeight, evmHeightStream, fuelHeight, svmHeight]).toEqual([
      [expected(Evm)],
      [expected(Evm)],
      [expected(Fuel)],
      [expected(Svm)],
    ])
  })
})
