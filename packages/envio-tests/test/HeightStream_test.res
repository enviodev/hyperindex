open Vitest

let statusLabel = (status: Source.heightSubscriptionStatus) =>
  switch status {
  | Live => "live"
  | Down({reason}) => `down:${reason}`
  }

type harness = {
  statuses: array<string>,
  heights: array<int>,
  // One entry per connection attempt, so its length is the number of connects.
  drivers: array<HeightStream.driver>,
  closes: ref<int>,
  unsubscribe: unit => unit,
}

let makeHarness = (~staleTimeout=15_000, ~failOnConnect=?, ~throwOnConnect=false) => {
  let statuses = []
  let heights = []
  let drivers = []
  let closes = ref(0)
  let unsubscribe = HeightStream.subscribe(
    ~staleTimeout,
    ~onHeight=height => heights->Array.push(height)->ignore,
    ~onStatus=status => statuses->Array.push(status->statusLabel)->ignore,
    ~connect=driver => {
      drivers->Array.push(driver)->ignore
      if throwOnConnect {
        JsError.throwWithMessage("Invalid URL")
      }
      switch failOnConnect {
      | Some(reason) => driver.onFailure(~reason)
      | None => ()
      }
      () => closes := closes.contents + 1
    },
  )
  {statuses, heights, drivers, closes, unsubscribe}
}

let driverAt = (harness, index): HeightStream.driver => harness.drivers->Array.getUnsafe(index)

describe("HeightStream reconnect driver", () => {
  beforeEach(() => Vi.useFakeTimers())
  afterEach(() => Vi.useRealTimers())

  Async.it("Backs off exponentially to a 60s cap and never gives up", async t => {
    let harness = makeHarness()
    // Deliberately longer than the 9 retries the WebSocket stream used to stop
    // after, so a regression back to giving up fails here.
    let schedule = [250, 500, 1_000, 2_000, 4_000, 8_000, 16_000, 32_000, 60_000, 60_000]

    let connectsAroundRetry = []
    for attempt in 0 to schedule->Array.length - 1 {
      (harness->driverAt(attempt)).onFailure(~reason="closed")
      await Vi.advanceTimersByTimeAsync(schedule->Array.getUnsafe(attempt) - 1)
      let beforeDue = harness.drivers->Array.length
      await Vi.advanceTimersByTimeAsync(1)
      connectsAroundRetry->Array.push((beforeDue, harness.drivers->Array.length))->ignore
    }
    harness.unsubscribe()

    t.expect(connectsAroundRetry).toStrictEqual(
      schedule->Array.mapWithIndex((_, attempt) => (attempt + 1, attempt + 2)),
    )
  })

  Async.it("Resets the backoff once a connection has lasted", async t => {
    let harness = makeHarness()
    // Exactly the retry delay each time, so no connection lives long enough to
    // also go stale.
    for attempt in 0 to 2 {
      (harness->driverAt(attempt)).onFailure(~reason="closed")
      await Vi.advanceTimersByTimeAsync(250 * Math.Int.pow(2, ~exp=attempt))
    }
    let reconnected = harness->driverAt(3)
    reconnected.onConnected()
    // Kept alive across more than a staleness window, so the connection counts
    // as having worked.
    await Vi.advanceTimersByTimeAsync(14_000)
    reconnected.onKeepAlive()
    await Vi.advanceTimersByTimeAsync(14_000)
    reconnected.onFailure(~reason="closed")

    await Vi.advanceTimersByTimeAsync(249)
    let beforeFirstStep = harness.drivers->Array.length
    await Vi.advanceTimersByTimeAsync(1)
    harness.unsubscribe()

    t.expect((beforeFirstStep, harness.drivers->Array.length, harness.statuses)).toStrictEqual((
      4,
      5,
      ["down:closed", "down:closed", "down:closed", "live", "down:closed"],
    ))
  })

  Async.it("Keeps backing off when short connections deliver a height each time", async t => {
    let harness = makeHarness()
    // HyperSync sends the head as soon as it connects, so an endpoint that
    // accepts a connection and drops it straight away still looks like it
    // carried traffic. Only its lifetime says otherwise.
    let schedule = [250, 500, 1_000, 2_000]

    let connectsAroundRetry = []
    for attempt in 0 to schedule->Array.length - 1 {
      let driver = harness->driverAt(attempt)
      driver.onConnected()
      driver.onHeight(100 + attempt)
      driver.onFailure(~reason="closed")
      await Vi.advanceTimersByTimeAsync(schedule->Array.getUnsafe(attempt) - 1)
      let beforeDue = harness.drivers->Array.length
      await Vi.advanceTimersByTimeAsync(1)
      connectsAroundRetry->Array.push((beforeDue, harness.drivers->Array.length))->ignore
    }
    harness.unsubscribe()

    t.expect(connectsAroundRetry).toStrictEqual(
      schedule->Array.mapWithIndex((_, attempt) => (attempt + 1, attempt + 2)),
    )
  })

  Async.it("Counts a socket that errors and then closes as one failure", async t => {
    let harness = makeHarness()
    let driver = harness->driverAt(0)
    driver.onConnected()
    driver.onFailure(~reason="error")
    driver.onFailure(~reason="closed")

    await Vi.advanceTimersByTimeAsync(250)
    harness.unsubscribe()

    t.expect((harness.statuses, harness.closes.contents, harness.drivers->Array.length)).toStrictEqual((
      ["live", "down:error"],
      // One close for the failed connection, one for the unsubscribe.
      2,
      2,
    ))
  })

  Async.it("Fails a connection that goes quiet for the stale timeout", async t => {
    let harness = makeHarness()
    (harness->driverAt(0)).onConnected()

    await Vi.advanceTimersByTimeAsync(14_999)
    let beforeStale = harness.statuses->Array.copy
    await Vi.advanceTimersByTimeAsync(1)
    harness.unsubscribe()

    t.expect((beforeStale, harness.statuses)).toStrictEqual((
      ["live"],
      ["live", "down:stale"],
    ))
  })

  Async.it("Names a stale failure after a message it could not read", async t => {
    let harness = makeHarness()
    let driver = harness->driverAt(0)
    driver.onConnected()
    driver.onUnreadable()

    // An unreadable message is not traffic, so the connection still goes quiet;
    // the point is that the failure says why rather than looking like a chain
    // with nothing to report.
    await Vi.advanceTimersByTimeAsync(15_000)
    let afterFirst = harness.statuses->Array.copy

    // The retry starts clean, so one stray message doesn't label every later
    // failure.
    await Vi.advanceTimersByTimeAsync(250)
    (harness->driverAt(1)).onConnected()
    await Vi.advanceTimersByTimeAsync(15_000)
    harness.unsubscribe()

    t.expect((afterFirst, harness.statuses)).toStrictEqual((
      ["live", "down:unreadable"],
      ["live", "down:unreadable", "live", "down:stale"],
    ))
  })

  Async.it("Keeps a connection alive on keep-alive traffic and on heights", async t => {
    let harness = makeHarness()
    let driver = harness->driverAt(0)
    driver.onConnected()

    await Vi.advanceTimersByTimeAsync(14_000)
    driver.onKeepAlive()
    await Vi.advanceTimersByTimeAsync(14_000)
    driver.onHeight(42)
    await Vi.advanceTimersByTimeAsync(14_000)
    let beforeStale = harness.statuses->Array.copy
    await Vi.advanceTimersByTimeAsync(1_000)
    harness.unsubscribe()

    t.expect((beforeStale, harness.statuses, harness.heights)).toStrictEqual((
      ["live"],
      ["live", "down:stale"],
      [42],
    ))
  })

  Async.it("Ignores everything a connection reports after unsubscribing", async t => {
    let harness = makeHarness()
    let driver = harness->driverAt(0)
    driver.onConnected()
    harness.unsubscribe()

    driver.onHeight(7)
    driver.onFailure(~reason="closed")
    driver.onConnected()
    await Vi.advanceTimersByTimeAsync(60_000)

    t.expect((
      harness.statuses,
      harness.heights,
      harness.drivers->Array.length,
      harness.closes.contents,
    )).toStrictEqual((["live"], [], 1, 1))
  })

  Async.it("Retries at the base delay after an established connection goes stale", async t => {
    let harness = makeHarness()
    // A chain whose blocks are further apart than the stale timeout ends every
    // connection this way, and the timeout already spaces the retries out, so
    // the backoff must not ratchet up on a working endpoint.
    let connectsAroundRetry = []
    for attempt in 0 to 3 {
      (harness->driverAt(attempt)).onConnected()
      await Vi.advanceTimersByTimeAsync(15_000)
      await Vi.advanceTimersByTimeAsync(249)
      let beforeDue = harness.drivers->Array.length
      await Vi.advanceTimersByTimeAsync(1)
      connectsAroundRetry->Array.push((beforeDue, harness.drivers->Array.length))->ignore
    }
    harness.unsubscribe()

    t.expect(connectsAroundRetry).toStrictEqual([(1, 2), (2, 3), (3, 4), (4, 5)])
  })

  Async.it("Keeps retrying when the transport throws while connecting", async t => {
    // Reached through a malformed url: escaping the retry timer would take the
    // process down instead.
    let harness = makeHarness(~throwOnConnect=true)

    await Vi.advanceTimersByTimeAsync(249)
    let beforeRetry = harness.drivers->Array.length
    await Vi.advanceTimersByTimeAsync(1)
    harness.unsubscribe()

    t.expect((beforeRetry, harness.drivers->Array.length, harness.statuses)).toStrictEqual((
      1,
      2,
      ["down:connect-failed", "down:connect-failed"],
    ))
  })

  Async.it("Retries rather than waits for staleness when connect fails immediately", async t => {
    let harness = makeHarness(~failOnConnect="401")

    await Vi.advanceTimersByTimeAsync(249)
    let beforeRetry = harness.drivers->Array.length
    await Vi.advanceTimersByTimeAsync(1)
    harness.unsubscribe()

    t.expect((beforeRetry, harness.drivers->Array.length, harness.statuses)).toStrictEqual((
      1,
      2,
      ["down:401", "down:401"],
    ))
  })
})

module NodeHttp = {
  type incomingMessage
  type serverResponse
  type t
  type address = {port: int}

  @module("node:http")
  external createServer: ((incomingMessage, serverResponse) => unit) => t = "createServer"

  @send external listen: (t, int, string, unit => unit) => unit = "listen"
  @send external close: (t, unit => unit) => unit = "close"
  @send external address: t => address = "address"
  @send external writeHead: (serverResponse, int, dict<string>) => unit = "writeHead"
  @send external write: (serverResponse, string) => unit = "write"
  @send external endWith: (serverResponse, string) => unit = "end"
  @send external end: (serverResponse, unit) => unit = "end"
}

module WsServer = {
  type socket
  type t
  type address = {port: int}

  @module("ws") @new external make: {"port": int} => t = "WebSocketServer"
  @send external onListening: (t, @as("listening") _, unit => unit) => unit = "on"
  @send external onConnection: (t, @as("connection") _, socket => unit) => unit = "on"
  @send external address: t => address = "address"
  @send external close: (t, unit => unit) => unit = "close"
  @send external onMessage: (socket, @as("message") _, 'data => unit) => unit = "on"
  @send external send: (socket, string) => unit = "send"
  @send external toString: 'data => string = "toString"
}

let waitUntil = async (predicate: unit => bool) => {
  let deadline = Performance.now() +. 5_000.
  let rec loop = async () =>
    if predicate() {
      ()
    } else if Performance.now() > deadline {
      JsError.throwWithMessage("Timed out waiting for the height stream")
    } else {
      await Utils.delay(5)
      await loop()
    }
  await loop()
}

let listenHttp = handler => {
  let server = NodeHttp.createServer(handler)
  Promise.make((resolve, _reject) =>
    server->NodeHttp.listen(0, "127.0.0.1", () =>
      resolve((server, `http://127.0.0.1:${(server->NodeHttp.address).port->Int.toString}`))
    )
  )
}

let listenWs = onConnection => {
  let server = WsServer.make({"port": 0})
  server->WsServer.onConnection(onConnection)
  Promise.make((resolve, _reject) =>
    server->WsServer.onListening(() =>
      resolve((server, `ws://127.0.0.1:${(server->WsServer.address).port->Int.toString}`))
    )
  )
}

describe("HyperSyncHeightStream", () => {
  Async.it("Reports the HTTP status as the failure reason", async t => {
    let (server, url) = await listenHttp((_request, response) => {
      response->NodeHttp.writeHead(401, Dict.fromArray([("Content-Type", "text/plain")]))
      response->NodeHttp.endWith("unauthorized")
    })
    let statuses = []
    let unsubscribe = HyperSyncHeightStream.subscribe(
      ~hyperSyncUrl=url,
      ~apiToken="bad-token",
      ~onHeight=_ => (),
      ~onStatus=status => statuses->Array.push(status->statusLabel)->ignore,
    )

    await waitUntil(() => statuses->Array.length > 0)
    unsubscribe()
    await Promise.make((resolve, _reject) => server->NodeHttp.close(() => resolve()))

    t.expect(statuses).toStrictEqual(["down:401"])
  })

  Async.it("Delivers heights and reports a clean stream end as closed", async t => {
    let (server, url) = await listenHttp((_request, response) => {
      response->NodeHttp.writeHead(
        200,
        Dict.fromArray([("Content-Type", "text/event-stream"), ("Cache-Control", "no-cache")]),
      )
      response->NodeHttp.write("event: height\ndata: 123\n\n")
      // Ending the response drops the stream without an HTTP error, which is
      // how a load balancer rotating connections shows up.
      response->NodeHttp.end()
    })
    let statuses = []
    let heights = []
    let unsubscribe = HyperSyncHeightStream.subscribe(
      ~hyperSyncUrl=url,
      ~apiToken="test-token",
      ~onHeight=height => heights->Array.push(height)->ignore,
      ~onStatus=status => statuses->Array.push(status->statusLabel)->ignore,
    )

    await waitUntil(() => statuses->Array.includes("down:closed"))
    unsubscribe()
    await Promise.make((resolve, _reject) => server->NodeHttp.close(() => resolve()))

    t.expect((statuses, heights)).toStrictEqual((["live", "down:closed"], [123]))
  })
})

describe("RpcWebSocketHeightStream", () => {
  Async.it("Goes live on subscription confirmation and delivers new heads", async t => {
    let (server, url) = await listenWs(socket =>
      socket->WsServer.onMessage(data => {
        if data->WsServer.toString->String.includes("eth_subscribe") {
          socket->WsServer.send(`{"jsonrpc":"2.0","id":1,"result":"0xsub"}`)
          socket->WsServer.send(
            `{"jsonrpc":"2.0","method":"eth_subscription","params":{"subscription":"0xsub","result":{"number":"0x2a"}}}`,
          )
        }
      })
    )
    let statuses = []
    let heights = []
    let unsubscribe = RpcWebSocketHeightStream.subscribe(
      ~wsUrl=url,
      ~onHeight=height => heights->Array.push(height)->ignore,
      ~onStatus=status => statuses->Array.push(status->statusLabel)->ignore,
    )

    await waitUntil(() => heights->Array.length > 0)
    unsubscribe()
    await Promise.make((resolve, _reject) => server->WsServer.close(() => resolve()))

    t.expect((statuses, heights)).toStrictEqual((["live"], [42]))
  })

  Async.it("Stays down while the socket opens but never confirms the subscription", async t => {
    // Answering with something the stream can't read must not count as
    // confirmation, nor bring the connection down on its own.
    let (server, url) = await listenWs(socket =>
      socket->WsServer.onMessage(_data => socket->WsServer.send("not json at all"))
    )
    let statuses = []
    let unsubscribe = RpcWebSocketHeightStream.subscribe(
      ~wsUrl=url,
      ~onHeight=_ => (),
      ~onStatus=status => statuses->Array.push(status->statusLabel)->ignore,
    )

    await Utils.delay(200)
    unsubscribe()
    await Promise.make((resolve, _reject) => server->WsServer.close(() => resolve()))

    t.expect(statuses).toStrictEqual([])
  })

  Async.it("Reports a rejected eth_subscribe without giving up", async t => {
    let (server, url) = await listenWs(socket =>
      socket->WsServer.onMessage(_data =>
        socket->WsServer.send(
          `{"jsonrpc":"2.0","id":1,"error":{"code":-32601,"message":"not supported"}}`,
        )
      )
    )
    let statuses = []
    let unsubscribe = RpcWebSocketHeightStream.subscribe(
      ~wsUrl=url,
      ~onHeight=_ => (),
      ~onStatus=status => statuses->Array.push(status->statusLabel)->ignore,
    )

    // Long enough for the first retry to reconnect and be rejected again.
    await waitUntil(() => statuses->Array.length > 1)
    unsubscribe()
    await Promise.make((resolve, _reject) => server->WsServer.close(() => resolve()))

    t.expect(statuses).toStrictEqual(["down:subscribe-rejected", "down:subscribe-rejected"])
  })
})
