open Vitest

// The height streams as an indexer at the head runs them: a chain whose YAML
// points at a local RPC node with a ws url, or at a local HyperSync server, both
// scripted by the test. The ports are fixed: the config naming them is parsed
// while vitest collects, before any hook could report a random one.
let rpcPort = 18652
let wsPort = 18653
// Nothing listens here, so every connect is refused.
let refusedWsPort = 18654
let hyperSyncPort = 18655

module WsServer = {
  type socket
  type t

  @module("ws") @new external make: {"port": int, "host": string} => t = "WebSocketServer"
  @send external onListening: (t, @as("listening") _, unit => unit) => unit = "on"
  @send external onConnection: (t, @as("connection") _, socket => unit) => unit = "on"
  @send external close: (t, unit => unit) => unit = "close"
  @send external onMessage: (socket, @as("message") _, 'data => unit) => unit = "on"
  @send external send: (socket, string) => unit = "send"
  @send external sendBinary: (socket, NodeJs.Buffer.t) => unit = "send"
  @send external closeSocket: socket => unit = "close"
  @send external terminate: socket => unit = "terminate"
  @send external toString: 'data => string = "toString"
  @send external onClose: (socket, @as("close") _, unit => unit) => unit = "on"
}

// What the node does with each eth_subscribe it is sent, and the HyperSync
// server with each `/height/sse` request, set by the test. A run can reach the
// head and subscribe before its body sets them, so whatever arrives first waits
// for them: the clock hasn't moved by then, so answering late is answering at
// the same instant.
let onSubscribe: ref<option<WsServer.socket => unit>> = ref(None)
let unansweredSubscribes: array<WsServer.socket> = []
let onSseRequest: ref<option<MockRpcServer.res => unit>> = ref(None)
let unansweredSseRequests: array<MockRpcServer.res> = []
// This test's sockets and streams, oldest first. Earlier tests' sockets are
// kept apart, to be dropped at the end should a failed test leave one open.
let sockets: array<WsServer.socket> = []
let earlierSockets: array<WsServer.socket> = []
let sseResponses: array<MockRpcServer.res> = []

let empty = array => array->Array.splice(~start=0, ~remove=array->Array.length, ~insert=[])

beforeEach(() => {
  earlierSockets->Array.pushMany(sockets)
  sockets->empty
  sseResponses->empty
  unansweredSubscribes->empty
  unansweredSseRequests->empty
  onSubscribe := None
  onSseRequest := None
})

let setUp = (~onSubscribe as subscribe=_ => (), ~onSseRequest as sse=_ => ()) => {
  onSubscribe := Some(subscribe)
  onSseRequest := Some(sse)
  unansweredSubscribes->Array.forEach(subscribe)
  unansweredSseRequests->Array.forEach(sse)
  unansweredSubscribes->empty
  unansweredSseRequests->empty
}

// Serves `/height/sse` itself and hands every other request to `upstream`, so
// the source's queries and height polls reach a real HyperSync server while
// its stream is the test's to script.
let startHyperSyncFront: (
  int,
  string,
  MockRpcServer.res => unit,
) => promise<unit => promise<unit>> = %raw(`async function (port, upstream, onSse) {
  const http = await import("node:http");
  const server = http.createServer(async (req, res) => {
    if (req.url === "/height/sse") {
      onSse(res);
      return;
    }
    const chunks = [];
    for await (const chunk of req) chunks.push(chunk);
    const body = Buffer.concat(chunks);
    const headers = { ...req.headers };
    for (const name of ["host", "content-length", "accept-encoding", "connection"]) delete headers[name];
    try {
      const answer = await fetch(upstream + req.url, {
        method: req.method,
        headers,
        body: body.length > 0 ? body : undefined,
      });
      const answerHeaders = {};
      answer.headers.forEach((value, name) => {
        if (!["content-encoding", "content-length", "transfer-encoding", "connection"].includes(name)) {
          answerHeaders[name] = value;
        }
      });
      res.writeHead(answer.status, answerHeaders);
      res.end(Buffer.from(await answer.arrayBuffer()));
    } catch (error) {
      res.writeHead(502);
      res.end(String(error));
    }
  });
  await new Promise((resolve) => server.listen(port, "127.0.0.1", resolve));
  return () => {
    server.closeAllConnections();
    return new Promise((resolve) => server.close(() => resolve()));
  };
}`)

// Only a head pushed past it brings the chain to this log, whose transaction
// the node can't serve the selected `gas` of.
let unservableBlock = 200
let unservableLog: ServedEvmChain.log = {
  blockNumber: unservableBlock,
  logIndex: 0,
  address: "0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3",
  // keccak256("TestEvent()")
  topics: ["0x24ec1d3ff24c2f6ff210738839dbc339cd45a5294d85c79361016243157aae7b"],
}

let rpcServer = ref(None)
let wsServer = ref(None)
let hyperSyncServer = ref(None)
let closeHyperSyncFront = ref(None)
Async.beforeAll(async () => {
  rpcServer :=
    Some(
      await MockRpcServer.makeWithParams(~port=rpcPort, ~getResult=(~method, ~params) =>
        switch method {
        | "eth_blockNumber" => JSON.String(ServedEvmChain.hex(100))
        | "eth_getLogs" =>
          let filter =
            params
            ->JSON.Decode.array
            ->Option.getOrThrow
            ->Array.getUnsafe(0)
            ->JSON.Decode.object
            ->Option.getOrThrow
          let block = key => filter->Dict.get(key)->Option.getOrThrow->ServedEvmChain.quantity
          block("fromBlock") <= unservableBlock && unservableBlock <= block("toBlock")
            ? JSON.Array([unservableLog->ServedEvmChain.rpcLog])
            : JSON.Array([])
        // A node that leaves out a field the config selects.
        | "eth_getTransactionByHash" =>
          JSON.Object(dict{"hash": JSON.String(unservableLog->ServedEvmChain.transactionHash)})
        | "eth_getBlockByNumber" =>
          params
          ->JSON.Decode.array
          ->Option.getOrThrow
          ->Array.getUnsafe(0)
          ->ServedEvmChain.quantity
          ->ServedEvmChain.rpcBlock
        | "eth_chainId" => JSON.String(ServedEvmChain.hex(1337))
        | _ => JsError.throwWithMessage(`Unexpected RPC method ${method}`)
        }
      ),
    )
  let server = WsServer.make({"port": wsPort, "host": "127.0.0.1"})
  server->WsServer.onConnection(socket => {
    sockets->Array.push(socket)->ignore
    socket->WsServer.onMessage(
      data =>
        if data->WsServer.toString->String.includes("eth_subscribe") {
          switch onSubscribe.contents {
          | Some(answer) => answer(socket)
          | None => unansweredSubscribes->Array.push(socket)
          }
        },
    )
  })
  await Promise.make((resolve, _reject) => server->WsServer.onListening(() => resolve()))
  wsServer := Some(server)

  let hyperSync = MockHyperSyncServer.make(~height=100)
  hyperSync->MockHyperSyncServer.serveChain(ServedEvmChain.hyperSyncChain(~logs=[], ~height=100))
  hyperSyncServer := Some(hyperSync)
  closeHyperSyncFront :=
    Some(
      await startHyperSyncFront(hyperSyncPort, hyperSync->MockHyperSyncServer.url, response => {
        sseResponses->Array.push(response)->ignore
        switch onSseRequest.contents {
        | Some(answer) => answer(response)
        | None => unansweredSseRequests->Array.push(response)
        }
      }),
    )
})
Async.afterAll(async () => {
  switch rpcServer.contents {
  | Some(server) => await server.closeAsync()
  | None => ()
  }
  switch wsServer.contents {
  | Some(server) =>
    Array.concat(earlierSockets, sockets)->Array.forEach(WsServer.terminate)
    await Promise.make((resolve, _reject) => server->WsServer.close(() => resolve()))
  | None => ()
  }
  switch closeHyperSyncFront.contents {
  | Some(close) => await close()
  | None => ()
  }
  switch hyperSyncServer.contents {
  | Some(server) => server->MockHyperSyncServer.close
  | None => ()
  }
})

let confirm = socket => socket->WsServer.send(`{"jsonrpc":"2.0","id":1,"result":"0xsub"}`)
let headFrame = blockNumber =>
  `{"jsonrpc":"2.0","method":"eth_subscription","params":{"subscription":"0xsub","result":{"number":"${ServedEvmChain.hex(
      blockNumber,
    )}"}}}`
let pushHead = (socket, blockNumber) => socket->WsServer.send(blockNumber->headFrame)
let rejection = (~id, ~message) =>
  `{"jsonrpc":"2.0","id":${id},"error":{"code":-32601,"message":"${message}"}}`
let latestSocket = () => sockets->Array.at(-1)->Option.getOrThrow(~message="no socket connected")

@send external flushHeaders: MockRpcServer.res => unit = "flushHeaders"
@send external onResponseClose: (MockRpcServer.res, @as("close") _, unit => unit) => unit = "on"
// Node holds headers back until the first body write, and the stream opens on
// the headers alone.
let openSse = response => {
  response->MockRpcServer.writeHead(
    200,
    dict{"Content-Type": "text/event-stream", "Cache-Control": "no-cache"},
  )
  response->flushHeaders
}
let latestSse = () => sseResponses->Array.at(-1)->Option.getOrThrow(~message="no stream requested")

let schema = `
type Gravatar {
  id: ID!
  owner: String!
}
`
let handlers = `
import { indexer } from "envio";
indexer.onEvent({ contract: "Gravatar", event: "TestEvent" }, async () => {});
`
let chainYaml = (~fieldSelection="", source) =>
  `
name: height-stream
${fieldSelection}rollback_on_reorg: false
contracts:
  - name: Gravatar
    events:
      - event: "TestEvent()"
chains:
  - id: 1337
${source}
    start_block: 100
    max_reorg_depth: 0
    contracts:
      - name: Gravatar
        address: "0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3"
`
let wsChain = (~fieldSelection=?, wsUrl) =>
  Scenario.make(
    ~schema,
    ~handlers,
    ~configYaml=chainYaml(
      ~fieldSelection?,
      `    rpc:
      url: http://127.0.0.1:${rpcPort->Int.toString}
      ws: ${wsUrl}
      for: sync
      polling_interval: 600000`,
    ),
  )

let ws = wsChain(`ws://127.0.0.1:${wsPort->Int.toString}`)
let selectingGas = wsChain(
  ~fieldSelection="field_selection:\n  transaction_fields:\n    - gas\n",
  `ws://127.0.0.1:${wsPort->Int.toString}`,
)
let refused = wsChain(`ws://127.0.0.1:${refusedWsPort->Int.toString}`)
// Past the last port, so the WebSocket constructor throws on it.
let unconnectable = wsChain("ws://127.0.0.1:99999")
let sse = Scenario.make(
  ~schema,
  ~handlers,
  ~configYaml=chainYaml(
    `    hypersync_config:
      url: http://127.0.0.1:${hyperSyncPort->Int.toString}`,
  ),
)

let wsStaleTimeout = 60_000
let sseStaleTimeout = 15_000

// Every time a stream went down, in order, as `(reason, detail)`.
let streamDowns = (indexer: IndexerRunner.t) =>
  indexer.allLogsAsJson()->Array.filterMap(line =>
    switch (line->Dict.get("msg"), line->Dict.get("reason")) {
    | (Some(String(msg)), Some(String(reason))) if msg->String.includes("went down") =>
      Some((
        reason,
        switch line->Dict.get("detail") {
        | Some(String(detail)) => Some(detail)
        | _ => None
        },
      ))
    | _ => None
    }
  )
let streamDownReasons = indexer => indexer->streamDowns->Array.map(((reason, _)) => reason)

let metricValues = async (indexer: IndexerRunner.t, name) =>
  (await indexer.metric(name))->Array.map(({value}) => value)
let connects = indexer => indexer->metricValues("envio_source_height_stream_connects_total")

let waitForMetric = async (indexer, name, expected) => {
  let deadline = Date.now() +. 5_000.
  while (await indexer->metricValues(name)) != expected {
    if Date.now() > deadline {
      JsError.throwWithMessage(
        `Timed out waiting for ${name} to read ${expected->Array.join(", ")}, got ${(
            await indexer->metricValues(name)
          )->Array.join(", ")}`,
      )
    }
    await Utils.delay(5)
  }
}
let waitForConnects = (indexer, count) =>
  indexer->waitForMetric("envio_source_height_stream_connects_total", [count->Int.toString])
let waitForKnownHeight = (indexer, height) =>
  indexer->waitForMetric("envio_source_known_height", [height->Int.toString])

let waitForDowns = (indexer, count) =>
  Scenario.waitUntil(
    () => indexer->streamDowns->Array.length >= count,
    ~message=`${count->Int.toString} height stream failures`,
  )
let waitForSockets = count =>
  Scenario.waitUntil(
    () => sockets->Array.length >= count,
    ~message=`${count->Int.toString} WebSocket connections`,
  )

// Lets frames and connects already on their way cross the real socket. Only
// for a check that something did not happen: there is nothing to wait on then.
let letSocketsSettle = () => Utils.delay(200)

// The retry wait is jittered across [delay/2, delay), so a test can only pin the
// window: nothing has reconnected before the earliest instant it could fire, and
// something has by the last one. Counted by `attempts`, from the instant the
// failure was reported, which the clock has not moved past.
let expectRetryWithin = async (indexer: IndexerRunner.t, ~delay, ~attempts) => {
  let before = attempts()
  await indexer.advanceTime(delay / 2 - 1)
  // Real time: a reconnect would have to cross a real socket to be counted.
  await letSocketsSettle()
  let early = attempts() - before
  await indexer.advanceTime(delay - delay / 2)
  await Scenario.waitUntil(() => attempts() > before, ~message="the stream to retry")
  (early, attempts() - before)
}
let reconnected = (0, 1)

// Drops the latest WebSocket from the node's side and pins when the stream
// tries again. Dropping it only once the clock has stopped is what makes the
// failure land at a known instant.
let dropAndExpectReconnectWithin = async (indexer, ~delay) => {
  let downs = indexer->streamDowns->Array.length
  latestSocket()->WsServer.closeSocket
  await indexer->waitForDowns(downs + 1)
  await indexer->expectRetryWithin(~delay, ~attempts=() => sockets->Array.length)
}

let sseRequests = () => sseResponses->Array.length

describe("WebSocket height stream", () => {
  ws->Scenario.it(
    "Goes live on subscription confirmation and delivers new heads",
    ~yamlSources=true,
    async (~t, ~indexer, ~source as _) => {
      setUp(
        ~onSubscribe=socket => {
          socket->confirm
          socket->pushHead(105)
        },
      )
      await indexer->waitForKnownHeight(105)
      t.expect((sockets->Array.length, await indexer->connects, indexer->streamDowns)).toEqual((
        1,
        ["1"],
        [],
      ))
    },
  )

  ws->Scenario.it(
    "Backs off exponentially to a 60s cap and never gives up",
    ~yamlSources=true,
    async (~t, ~indexer, ~source as _) => {
      setUp()
      await waitForSockets(1)
      let windows = []
      for step in 0 to 9 {
        let delay = Math.Int.min(250 * Math.Int.pow(2, ~exp=step), 60_000)
        windows->Array.push(await indexer->dropAndExpectReconnectWithin(~delay))->ignore
      }
      t.expect((windows, indexer->streamDownReasons)).toEqual((
        Array.make(~length=10, reconnected),
        Array.make(~length=10, "closed"),
      ))
    },
  )

  ws->Scenario.it(
    "Names a clean end after a connection that served its time a rotation, and starts the backoff over",
    ~yamlSources=true,
    async (~t, ~indexer, ~source as _) => {
      setUp(~onSubscribe=confirm)
      await indexer->waitForConnects(1)
      // Escalated once, by a connection that ended before it was worth making.
      let early = await indexer->dropAndExpectReconnectWithin(~delay=250)
      await indexer->waitForConnects(2)
      await indexer.advanceTime(15_000)
      let afterServing = await indexer->dropAndExpectReconnectWithin(~delay=250)
      t.expect((early, afterServing, indexer->streamDownReasons)).toEqual((
        reconnected,
        reconnected,
        ["closed", "rotated"],
      ))
    },
  )

  ws->Scenario.it(
    "Keeps backing off for a connection that never went live, however long it stayed open",
    ~yamlSources=true,
    async (~t, ~indexer, ~source as _) => {
      setUp()
      await waitForSockets(1)
      let first = await indexer->dropAndExpectReconnectWithin(~delay=250)
      await waitForSockets(2)
      // Past the bar a live connection would have to clear, but never live.
      await indexer.advanceTime(15_000)
      let second = await indexer->dropAndExpectReconnectWithin(~delay=500)
      t.expect((first, second, indexer->streamDownReasons)).toEqual((
        reconnected,
        reconnected,
        ["closed", "closed"],
      ))
    },
  )

  ws->Scenario.it(
    "Keeps backing off for short-lived connections that delivered heads",
    ~yamlSources=true,
    async (~t, ~indexer, ~source as _) => {
      setUp(
        ~onSubscribe=socket => {
          socket->confirm
          socket->pushHead(101)
        },
      )
      await indexer->waitForKnownHeight(101)
      let first = await indexer->dropAndExpectReconnectWithin(~delay=250)
      await indexer->waitForConnects(2)
      // A head is proof of delivery, not of a connection worth making.
      await indexer.advanceTime(1_000)
      let second = await indexer->dropAndExpectReconnectWithin(~delay=500)
      t.expect((first, second, indexer->streamDownReasons)).toEqual((
        reconnected,
        reconnected,
        ["closed", "closed"],
      ))
    },
  )

  ws->Scenario.it(
    "Starts the backoff over when a connection goes stale after serving, however far it had escalated",
    ~yamlSources=true,
    async (~t, ~indexer, ~source as _) => {
      setUp(~onSubscribe=confirm)
      await indexer->waitForConnects(1)
      let first = await indexer->dropAndExpectReconnectWithin(~delay=250)
      await indexer->waitForConnects(2)
      let second = await indexer->dropAndExpectReconnectWithin(~delay=500)
      await indexer->waitForConnects(3)
      // The stale window runs from when the connection went live, which the
      // clock doesn't pin, so walk up to the failure in steps short enough to
      // tell the two backoffs apart.
      let stepped = ref(0)
      while !(indexer->streamDownReasons->Array.includes("stale")) && stepped.contents < 61_000 {
        await indexer.advanceTime(100)
        stepped := stepped.contents + 100
      }
      let socketsAtStale = sockets->Array.length
      // Reset, the retry lands within 250ms of the failure. Still escalated, it
      // would wait at least 500ms.
      await indexer.advanceTime(300)
      await Scenario.waitUntil(
        () => sockets->Array.length > socketsAtStale,
        ~message="the stale stream to be retried at the base delay",
      )
      t.expect((first, second, indexer->streamDownReasons)).toEqual((
        reconnected,
        reconnected,
        ["closed", "closed", "stale"],
      ))
    },
  )

  ws->Scenario.it(
    "Stays down while the node answers the subscribe with nothing it can read",
    ~yamlSources=true,
    async (~t, ~indexer, ~source as _) => {
      setUp(~onSubscribe=socket => socket->WsServer.send("not json at all"))
      await waitForSockets(1)
      // Real time: the frame crosses a real socket, and is read to no effect.
      await letSocketsSettle()
      t.expect((await indexer->connects, indexer->streamDowns)).toEqual((["0"], []))
    },
  )

  ws->Scenario.it(
    "Keeps backing off when live connections die younger than the wait before them",
    ~yamlSources=true,
    async (~t, ~indexer, ~source as _) => {
      setUp(~onSubscribe=confirm)
      await indexer->waitForConnects(1)
      let first = await indexer->dropAndExpectReconnectWithin(~delay=250)
      await indexer->waitForConnects(2)
      // Served longer than the 250ms it waited, but not long enough to prove
      // anything against a stale window of a minute.
      await indexer.advanceTime(1_000)
      let second = await indexer->dropAndExpectReconnectWithin(~delay=500)
      t.expect((first, second, indexer->streamDownReasons)).toEqual((
        reconnected,
        reconnected,
        ["closed", "closed"],
      ))
    },
  )

  ws->Scenario.it(
    "Leaves a failure that is not a clean end alone, however long it served",
    ~yamlSources=true,
    async (~t, ~indexer, ~source as _) => {
      setUp(~onSubscribe=confirm)
      await indexer->waitForConnects(1)
      await indexer.advanceTime(15_000)
      latestSocket()->WsServer.send(rejection(~id="1", ~message="subscription dropped"))
      await indexer->waitForDowns(1)
      // It did serve, so the backoff starts over all the same.
      let retry = await indexer->expectRetryWithin(
        ~delay=250,
        ~attempts=() => sockets->Array.length,
      )
      t.expect((retry, indexer->streamDownReasons)).toEqual((reconnected, ["subscribe-rejected"]))
    },
  )

  ws->Scenario.it(
    "Fails a connection that goes quiet for the stale timeout, and retries it at the base delay",
    ~yamlSources=true,
    async (~t, ~indexer, ~source as _) => {
      setUp(~onSubscribe=confirm)
      await indexer->waitForConnects(1)
      await indexer.advanceTime(wsStaleTimeout - 1)
      let beforeStale = indexer->streamDownReasons
      await indexer.advanceTime(1)
      let retry = await indexer->expectRetryWithin(
        ~delay=250,
        ~attempts=() => sockets->Array.length,
      )
      t.expect((beforeStale, indexer->streamDownReasons, retry)).toEqual((
        [],
        ["stale"],
        reconnected,
      ))
    },
  )

  ws->Scenario.it("Closes its height stream when the indexer stops", ~yamlSources=true, async (
    ~t,
    ~indexer,
    ~source as _,
  ) => {
    let closed = ref(false)
    setUp(
      ~onSubscribe=socket => {
        socket->WsServer.onClose(() => closed := true)
        socket->confirm
      },
    )
    await indexer->waitForConnects(1)
    await indexer.stop()
    // Left open, a stopped indexer goes on taking heights from the provider.
    await Scenario.waitUntil(() => closed.contents, ~message="the stream to be closed")
    t.expect(sockets->Array.length).toBe(1)
  })

  ws->Scenario.it("Closes the socket of a connection it gave up on", ~yamlSources=true, async (
    ~t,
    ~indexer,
    ~source as _,
  ) => {
    let closed = ref(false)
    setUp(
      ~onSubscribe=socket => {
        socket->WsServer.onClose(() => closed := true)
        socket->confirm
      },
    )
    await indexer->waitForConnects(1)
    await indexer.advanceTime(wsStaleTimeout)
    // Left open, a stale socket would go on holding a slot at the provider.
    await Scenario.waitUntil(() => closed.contents, ~message="the stale socket to be closed")
    t.expect(indexer->streamDownReasons).toEqual(["stale"])
  })

  selectingGas->Scenario.it(
    "Closes the stream of a source it stops using",
    ~yamlSources=true,
    // The chain has no other source to turn to, which stops the indexer.
    ~onError=_ => (),
    async (~t, ~indexer, ~source as _) => {
      let closed = ref(false)
      setUp(~onSubscribe=socket => {
        socket->WsServer.onClose(() => closed := true)
        socket->confirm
      })
      await indexer->waitForConnects(1)
      latestSocket()->pushHead(unservableBlock)
      await Scenario.waitUntil(() => closed.contents, ~message="the stream to be closed")
      t.expect(
        (await indexer.metric("envio_source_height_stream_disconnects_total"))->Array.map(({
          labels,
          value,
        }) => (labels->Dict.get("reason"), value)),
      ).toEqual([(Some("unsubscribed"), "1")])
    },
  )

  ws->Scenario.it(
    "Counts a connection's service from when it went live, not from its latest head",
    ~yamlSources=true,
    async (~t, ~indexer, ~source as _) => {
      setUp(~onSubscribe=confirm)
      await indexer->waitForConnects(1)
      await indexer.advanceTime(14_000)
      latestSocket()->pushHead(101)
      await indexer->waitForKnownHeight(101)
      await indexer.advanceTime(1_000)
      let retry = await indexer->dropAndExpectReconnectWithin(~delay=250)
      t.expect((retry, indexer->streamDownReasons)).toEqual((reconnected, ["rotated"]))
    },
  )

  ws->Scenario.it(
    "Takes a readable head as the stream being readable again",
    ~yamlSources=true,
    async (~t, ~indexer, ~source as _) => {
      setUp(
        ~onSubscribe=socket => {
          socket->WsServer.send("not json at all")
          socket->pushHead(101)
        },
      )
      await indexer->waitForKnownHeight(101)
      await indexer.advanceTime(wsStaleTimeout)
      t.expect(indexer->streamDownReasons).toEqual(["stale"])
    },
  )

  ws->Scenario.it(
    "Fails a connection whose subscription is never answered for the stale timeout",
    ~yamlSources=true,
    async (~t, ~indexer, ~source as _) => {
      setUp()
      await waitForSockets(1)
      await indexer.advanceTime(wsStaleTimeout - 1)
      let beforeStale = indexer->streamDownReasons
      await indexer.advanceTime(1)
      t.expect((beforeStale, indexer->streamDownReasons, await indexer->connects)).toEqual((
        [],
        ["stale"],
        ["0"],
      ))
    },
  )

  ws->Scenario.it(
    "Keeps a connection that delivers heads alive past the stale timeout",
    ~yamlSources=true,
    async (~t, ~indexer, ~source as _) => {
      setUp(~onSubscribe=confirm)
      await indexer->waitForConnects(1)
      await indexer.advanceTime(50_000)
      latestSocket()->pushHead(101)
      await indexer->waitForKnownHeight(101)
      await indexer.advanceTime(50_000)
      let carried = indexer->streamDownReasons
      await indexer.advanceTime(10_000)
      t.expect((carried, indexer->streamDownReasons)).toEqual(([], ["stale"]))
    },
  )

  ws->Scenario.it("Treats a delivered head as proof the stream is live", ~yamlSources=true, async (
    ~t,
    ~indexer,
    ~source as _,
  ) => {
    setUp(~onSubscribe=socket => socket->pushHead(105))
    await indexer->waitForKnownHeight(105)
    t.expect(await indexer->connects).toEqual(["1"])
  })

  ws->Scenario.it(
    "Names a stale failure after a frame it could not read, with the frame",
    ~yamlSources=true,
    async (~t, ~indexer, ~source as _) => {
      setUp(
        ~onSubscribe=socket => {
          socket->WsServer.send("not json at all")
          // After the frame, so going live says the frame has been read.
          socket->confirm
        },
      )
      await indexer->waitForConnects(1)
      await indexer.advanceTime(wsStaleTimeout)
      t.expect(indexer->streamDowns).toEqual([("unreadable", Some("not json at all"))])
    },
  )

  ws->Scenario.it("Names a stream that sends binary frames unreadable", ~yamlSources=true, async (
    ~t,
    ~indexer,
    ~source as _,
  ) => {
    setUp(
      ~onSubscribe=socket => {
        socket->WsServer.sendBinary(NodeJs.Buffer.fromHex("2a"))
        socket->confirm
      },
    )
    await indexer->waitForConnects(1)
    await indexer.advanceTime(wsStaleTimeout)
    t.expect(indexer->streamDowns).toEqual([("unreadable", Some("binary frame"))])
  })

  ws->Scenario.it(
    "Treats valid JSON of no shape it knows as unreadable, not as a rejection",
    ~yamlSources=true,
    async (~t, ~indexer, ~source as _) => {
      setUp(
        ~onSubscribe=socket => {
          socket->WsServer.send(`{"jsonrpc":"2.0","hello":"world"}`)
          socket->confirm
        },
      )
      await indexer->waitForConnects(1)
      await indexer.advanceTime(wsStaleTimeout)
      t.expect(indexer->streamDowns).toEqual([
        ("unreadable", Some(`{"jsonrpc":"2.0","hello":"world"}`)),
      ])
    },
  )

  ws->Scenario.it("Trims an unreadable frame that would flood the log", ~yamlSources=true, async (
    ~t,
    ~indexer,
    ~source as _,
  ) => {
    let frame = "x"->String.repeat(300)
    setUp(
      ~onSubscribe=socket => {
        socket->WsServer.send(frame)
        socket->confirm
      },
    )
    await indexer->waitForConnects(1)
    await indexer.advanceTime(wsStaleTimeout)
    t.expect(indexer->streamDowns).toEqual([
      ("unreadable", Some(frame->String.slice(~start=0, ~end=200) ++ "...")),
    ])
  })

  ws->Scenario.it("Trims a failure detail that would flood the log", ~yamlSources=true, async (
    ~t,
    ~indexer,
    ~source as _,
  ) => {
    let frame = rejection(~id="1", ~message="x"->String.repeat(300))
    setUp(~onSubscribe=socket => socket->WsServer.send(frame))
    await indexer->waitForDowns(1)
    t.expect(indexer->streamDowns).toEqual([
      ("subscribe-rejected", Some(frame->String.slice(~start=0, ~end=200) ++ "...")),
    ])
  })

  ws->Scenario.it("Reports a rejected eth_subscribe without giving up", ~yamlSources=true, async (
    ~t,
    ~indexer,
    ~source as _,
  ) => {
    setUp(~onSubscribe=socket => socket->WsServer.send(rejection(~id="1", ~message="no")))
    await indexer->waitForDowns(1)
    let retry = await indexer->expectRetryWithin(
      ~delay=250,
      ~attempts=() => indexer->streamDowns->Array.length,
    )
    t.expect((retry, indexer->streamDownReasons)).toEqual((
      reconnected,
      ["subscribe-rejected", "subscribe-rejected"],
    ))
  })

  ws->Scenario.it(
    "Reports a rejection the provider answered with a null id",
    ~yamlSources=true,
    async (~t, ~indexer, ~source as _) => {
      // JSON-RPC answers a request it could not parse with an explicit null id.
      // The subscribe is the only request this socket ever sends, so an error
      // naming no id is still that subscription being refused.
      setUp(~onSubscribe=socket => socket->WsServer.send(rejection(~id="null", ~message="parse")))
      await indexer->waitForDowns(1)
      t.expect(indexer->streamDownReasons).toEqual(["subscribe-rejected"])
    },
  )

  ws->Scenario.it(
    "Reads a rejection whose id the provider echoed as a string",
    ~yamlSources=true,
    async (~t, ~indexer, ~source as _) => {
      // Failing to match one costs the whole stale window before the rejection
      // is reported, under a reason the provider never gave.
      setUp(~onSubscribe=socket => socket->WsServer.send(rejection(~id=`"1"`, ~message="no")))
      await indexer->waitForDowns(1)
      t.expect(indexer->streamDownReasons).toEqual(["subscribe-rejected"])
    },
  )

  ws->Scenario.it(
    "Confirms a subscription whose id came back as a string",
    ~yamlSources=true,
    async (~t, ~indexer, ~source as _) => {
      setUp(
        ~onSubscribe=socket => socket->WsServer.send(`{"jsonrpc":"2.0","id":"1","result":"0xsub"}`),
      )
      await indexer->waitForConnects(1)
      t.expect(indexer->streamDowns).toEqual([])
    },
  )

  ws->Scenario.it(
    "Keeps a delivering connection through errors meant for something else",
    ~yamlSources=true,
    async (~t, ~indexer, ~source as _) => {
      setUp(
        ~onSubscribe=socket => {
          socket->confirm
          // A provider talking about some other request, and then about itself:
          // once the subscribe is confirmed, a null id is no longer its answer.
          socket->WsServer.send(rejection(~id="7", ~message="rate limited"))
          socket->WsServer.send(rejection(~id="null", ~message="rate limited"))
          socket->pushHead(105)
        },
      )
      await indexer->waitForKnownHeight(105)
      t.expect((await indexer->connects, indexer->streamDowns)).toEqual((["1"], []))
    },
  )

  ws->Scenario.it(
    "Ignores a success frame that answers no request this socket made",
    ~yamlSources=true,
    async (~t, ~indexer, ~source as _) => {
      // Taking it for the subscribe being confirmed reports a stream as live
      // while nothing was ever subscribed.
      setUp(
        ~onSubscribe=socket =>
          socket->WsServer.send(`{"jsonrpc":"2.0","id":7,"result":"0xsomethingelse"}`),
      )
      await waitForSockets(1)
      // Real time: the frame crosses a real socket, and is read to no effect.
      await letSocketsSettle()
      t.expect((await indexer->connects, indexer->streamDowns)).toEqual((["0"], []))
    },
  )
})

describe("WebSocket height stream that cannot connect", () => {
  refused->Scenario.it(
    "Counts a socket that errors and then closes as one failure, and retries it",
    ~yamlSources=true,
    async (~t, ~indexer, ~source as _) => {
      await indexer->waitForDowns(1)
      // Real time: the close that follows the error crosses the event loop.
      await letSocketsSettle()
      let reported = indexer->streamDownReasons
      let retry = await indexer->expectRetryWithin(
        ~delay=250,
        ~attempts=() => indexer->streamDowns->Array.length,
      )
      t.expect((reported, retry)).toEqual((["error"], reconnected))
    },
  )

  unconnectable->Scenario.it(
    "Retries a url it cannot even open a socket to, without waiting out the stale timeout",
    ~yamlSources=true,
    async (~t, ~indexer, ~source as _) => {
      await indexer->waitForDowns(1)
      let retry = await indexer->expectRetryWithin(
        ~delay=250,
        ~attempts=() => indexer->streamDowns->Array.length,
      )
      t.expect((
        retry,
        indexer
        ->streamDowns
        ->Array.map(((reason, detail)) => (reason, detail->Option.isSome)),
      )).toEqual((reconnected, [("connect-failed", true), ("connect-failed", true)]))
    },
  )
})

describe("HyperSync height stream", () => {
  sse->Scenario.it(
    "Delivers heights and reports a clean stream end as closed",
    ~yamlSources=true,
    async (~t, ~indexer, ~source as _) => {
      setUp(
        ~onSseRequest=response => {
          response->openSse
          response->MockRpcServer.write("event: height\ndata: 105\n\n")
        },
      )
      await indexer->waitForKnownHeight(105)
      // Ending the response drops the stream without an HTTP error, which is
      // how a load balancer rotating connections shows up.
      latestSse()->MockRpcServer.endStream()
      await indexer->waitForDowns(1)
      t.expect((await indexer->connects, indexer->streamDownReasons)).toEqual((["1"], ["closed"]))
    },
  )

  sse->Scenario.it(
    "Reports the HTTP status as the failure reason, with the server's message",
    ~yamlSources=true,
    async (~t, ~indexer, ~source as _) => {
      setUp(
        ~onSseRequest=response => {
          response->MockRpcServer.writeHead(401, dict{"Content-Type": "text/plain"})
          response->MockRpcServer.end_("unauthorized")
        },
      )
      await indexer->waitForDowns(1)
      let retry = await indexer->expectRetryWithin(~delay=250, ~attempts=sseRequests)
      await indexer->waitForDowns(2)
      // The status alone can't tell an operator which of a provider's many
      // 401s this was, so the transport has to carry its message out too.
      t.expect((
        retry,
        indexer
        ->streamDowns
        ->Array.map(((reason, detail)) => (reason, detail->Option.isSome)),
      )).toEqual((reconnected, [("http-401", true), ("http-401", true)]))
    },
  )

  sse->Scenario.it(
    "Reports a connection that fails without an HTTP status as a transport error",
    ~yamlSources=true,
    async (~t, ~indexer, ~source as _) => {
      setUp(~onSseRequest=MockRpcServer.destroy)
      await indexer->waitForDowns(1)
      t.expect(indexer->streamDownReasons).toEqual(["error"])
    },
  )

  sse->Scenario.it("Closes a stream that went quiet, and retries it", ~yamlSources=true, async (
    ~t,
    ~indexer,
    ~source as _,
  ) => {
    let closed = ref(false)
    setUp(
      ~onSseRequest=response => {
        if sseResponses->Array.length === 1 {
          response->onResponseClose(() => closed := true)
        }
        response->openSse
      },
    )
    await indexer->waitForConnects(1)
    await indexer.advanceTime(sseStaleTimeout)
    await Scenario.waitUntil(() => closed.contents, ~message="the quiet stream to be closed")
    let retry = await indexer->expectRetryWithin(~delay=250, ~attempts=sseRequests)
    t.expect((indexer->streamDownReasons, retry)).toEqual((["stale"], reconnected))
  })

  sse->Scenario.it("Keeps a connection alive on keep-alive pings", ~yamlSources=true, async (
    ~t,
    ~indexer,
    ~source as _,
  ) => {
    setUp(~onSseRequest=openSse)
    await indexer->waitForConnects(1)
    await indexer.advanceTime(10_000)
    latestSse()->MockRpcServer.write("event: ping\ndata:\n\n")
    // Real time: the ping crosses a real socket.
    await letSocketsSettle()
    await indexer.advanceTime(10_000)
    let carried = indexer->streamDownReasons
    await indexer.advanceTime(sseStaleTimeout)
    t.expect((carried, indexer->streamDownReasons)).toEqual(([], ["stale"]))
  })

  sse->Scenario.it(
    "Names a stream whose heights it cannot read unreadable, however many pings keep it open",
    ~yamlSources=true,
    async (~t, ~indexer, ~source as _) => {
      setUp(
        ~onSseRequest=response => {
          response->openSse
          response->MockRpcServer.write("event: height\ndata: not-a-number\n\n")
        },
      )
      await indexer->waitForConnects(1)
      // Real time: the frame follows the open on the same real response.
      await letSocketsSettle()
      await indexer.advanceTime(10_000)
      latestSse()->MockRpcServer.write("event: ping\ndata:\n\n")
      // Real time: the ping crosses a real socket.
      await letSocketsSettle()
      await indexer.advanceTime(sseStaleTimeout - 10_000)
      t.expect(indexer->streamDowns).toEqual([("unreadable", Some("not-a-number"))])
    },
  )
})
