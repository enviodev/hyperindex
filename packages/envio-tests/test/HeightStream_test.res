open Vitest

let statusLabel = (status: Source.heightSubscriptionStatus) =>
  switch status {
  | Live => "live"
  | Down({reason} as down) =>
    let reason = reason->Source.downReasonLabel
    switch down.detail {
    | Some(detail) => `down:${reason}:${detail}`
    | None => `down:${reason}`
    }
  }

// A provider's error text is its own, so the transport tests assert only the
// bucketed reason they have to keep stable.
let reasonLabel = (status: Source.heightSubscriptionStatus) =>
  switch status {
  | Live => "live"
  | Down({reason}) => `down:${reason->Source.downReasonLabel}`
  }

type harness = {
  statuses: array<string>,
  heights: array<int>,
  // One entry per connection attempt, so its length is the number of connects.
  drivers: array<HeightStream.driver>,
  closes: ref<int>,
  unsubscribe: unit => unit,
}

let makeHarness = (~staleTimeout=15_000, ~failOnConnect=?, ~throwOnConnect=false, ~throwOnClose=false) => {
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
      () => {
        closes := closes.contents + 1
        if throwOnClose {
          JsError.throwWithMessage("Socket already gone")
        }
      }
    },
  )
  {statuses, heights, drivers, closes, unsubscribe}
}

let driverAt = (harness, index): HeightStream.driver => harness.drivers->Array.getUnsafe(index)

// The retry wait is jittered across [delay/2, delay), so a test can only pin the
// window: nothing has reconnected before the earliest instant it could fire, and
// something has by the last one.
let advanceThroughRetryWindow = async (harness, ~delay) => {
  let earliest = delay / 2
  await Vi.advanceTimersByTimeAsync(earliest - 1)
  let beforeEarliest = harness.drivers->Array.length
  // Walk the rest of the window rather than jumping it, and stop as soon as the
  // reconnect lands. The connection it makes is live from that instant, so
  // jumping the remainder would run it through its own staleness timeout and
  // measure that instead of the backoff.
  let remaining = ref(delay - earliest)
  while remaining.contents > 0 && harness.drivers->Array.length === beforeEarliest {
    let step = Pervasives.min(remaining.contents, 500)
    await Vi.advanceTimersByTimeAsync(step)
    remaining := remaining.contents - step
  }
  (beforeEarliest, harness.drivers->Array.length)
}

describe("HeightStream reconnect driver", () => {
  beforeEach(() => Vi.useFakeTimers())
  afterEach(() => Vi.useRealTimers())

  it("Spreads a retry wait across the half-window below it", t => {
    // Every indexer on one provider loses its stream in the same instant when
    // that provider blinks; reconnecting them all on one schedule is what turns
    // a blip into a stampede.
    let samples = Belt.Array.makeBy(200, _ => Utils.jitter(1_000))
    let first = samples->Array.getUnsafe(0)

    t.expect((
      samples->Array.every(v => v >= 500 && v < 1_000),
      samples->Array.some(v => v !== first),
      // Nothing to spread on a first connection, which nothing preceded.
      Utils.jitter(0),
    )).toStrictEqual((true, true, 0))
  })

  Async.it("Backs off exponentially to a 60s cap and never gives up", async t => {
    let harness = makeHarness()
    // Long enough that a cap on the number of retries would fail here rather
    // than leaving the stream quietly dead.
    let schedule = [250, 500, 1_000, 2_000, 4_000, 8_000, 16_000, 32_000, 60_000, 60_000]

    let connectsAroundRetry = []
    for attempt in 0 to schedule->Array.length - 1 {
      (harness->driverAt(attempt)).onFailure(~reason=Source.Closed)
      connectsAroundRetry
      ->Array.push(
        await harness->advanceThroughRetryWindow(~delay=schedule->Array.getUnsafe(attempt)),
      )
      ->ignore
    }
    harness.unsubscribe()

    t.expect(connectsAroundRetry).toStrictEqual(
      schedule->Array.mapWithIndex((_, attempt) => (attempt + 1, attempt + 2)),
    )
  })

  Async.it("Resets the backoff for a connection that outlived the wait before it", async t => {
    // One newHeads block over a long life is all a WebSocket connection carries
    // on a slow chain, and every one of them was worth making, so what it
    // delivered must not be what decides this.
    let harness = makeHarness(~staleTimeout=60_000)
    (harness->driverAt(0)).onFailure(~reason=Source.Closed)
    await Vi.advanceTimersByTimeAsync(250)
    (harness->driverAt(1)).onFailure(~reason=Source.Closed)
    await Vi.advanceTimersByTimeAsync(500)

    let rotated = harness->driverAt(2)
    rotated.onConnected()
    await Vi.advanceTimersByTimeAsync(20_000)
    rotated.onHeight(101)
    rotated.onFailure(~reason=Source.Closed)

    let window = await harness->advanceThroughRetryWindow(~delay=250)
    harness.unsubscribe()

    t.expect(window).toStrictEqual((3, 4))
  })

  Async.it("Keeps backing off when connections die younger than the wait before them", async t => {
    let harness = makeHarness()
    // HyperSync sends the head as soon as it connects, so an endpoint that
    // accepts a connection and drops it has delivered everything a working one
    // would have by then. How long it held the connection open is what tells
    // them apart.
    let schedule = [250, 500, 1_000, 2_000]

    let connectsAroundRetry = []
    for attempt in 0 to schedule->Array.length - 1 {
      let driver = harness->driverAt(attempt)
      driver.onConnected()
      driver.onHeight(100 + attempt)
      await Vi.advanceTimersByTimeAsync(300)
      driver.onFailure(~reason=Source.Closed)
      connectsAroundRetry
      ->Array.push(
        await harness->advanceThroughRetryWindow(~delay=schedule->Array.getUnsafe(attempt)),
      )
      ->ignore
    }
    harness.unsubscribe()

    t.expect(connectsAroundRetry).toStrictEqual(
      schedule->Array.mapWithIndex((_, attempt) => (attempt + 1, attempt + 2)),
    )
  })

  Async.it("Keeps backing off when a connection never reports itself live", async t => {
    // A gateway that accepts the socket and answers 502 two seconds later, or a
    // handshake that takes that long to be reset, served nothing at all — only
    // time a connection spent live can pay for the wait it cost.
    let harness = makeHarness()
    let schedule = [250, 500, 1_000, 2_000]

    let connectsAroundRetry = []
    for attempt in 0 to schedule->Array.length - 1 {
      await Vi.advanceTimersByTimeAsync(2_000)
      (harness->driverAt(attempt)).onFailure(~reason=Source.Http(502))
      connectsAroundRetry
      ->Array.push(
        await harness->advanceThroughRetryWindow(~delay=schedule->Array.getUnsafe(attempt)),
      )
      ->ignore
    }
    harness.unsubscribe()

    t.expect(connectsAroundRetry).toStrictEqual(
      schedule->Array.mapWithIndex((_, attempt) => (attempt + 1, attempt + 2)),
    )
  })

  Async.it("Keeps backing off when a live connection dies inside the stale window", async t => {
    // A WebSocket that confirms the subscription and drops seconds later without
    // a head served no better than one that never connected, however far past a
    // second it lasted.
    let harness = makeHarness(~staleTimeout=60_000)
    let schedule = [250, 500, 1_000, 2_000]

    let connectsAroundRetry = []
    for attempt in 0 to schedule->Array.length - 1 {
      let driver = harness->driverAt(attempt)
      driver.onConnected()
      await Vi.advanceTimersByTimeAsync(3_000)
      driver.onFailure(~reason=Source.Closed)
      connectsAroundRetry
      ->Array.push(
        await harness->advanceThroughRetryWindow(~delay=schedule->Array.getUnsafe(attempt)),
      )
      ->ignore
    }
    harness.unsubscribe()

    t.expect(connectsAroundRetry).toStrictEqual(
      schedule->Array.mapWithIndex((_, attempt) => (attempt + 1, attempt + 2)),
    )
  })

  Async.it("Names a clean end after a proven connection a rotation", async t => {
    // A quarter of this is the bar a connection has to clear, and staying under
    // it is what keeps these connections from failing as stale instead.
    let harness = makeHarness(~staleTimeout=60_000)

    // Dies before it has served the quarter of the stale window that makes a
    // connection worth having made: a server dropping connections, not a
    // rotation.
    let young = harness->driverAt(0)
    young.onConnected()
    await Vi.advanceTimersByTimeAsync(10_000)
    young.onFailure(~reason=Source.Closed)
    await Vi.advanceTimersByTimeAsync(250)

    // Served well past it, then the stream ended without an error, which is
    // what a load balancer rotating connections looks like from here.
    let rotated = harness->driverAt(1)
    rotated.onConnected()
    await Vi.advanceTimersByTimeAsync(30_000)
    rotated.onFailure(~reason=Source.Closed)
    harness.unsubscribe()

    t.expect(harness.statuses).toStrictEqual([
      "live",
      "down:closed",
      "live",
      "down:rotated",
    ])
  })

  Async.it("Leaves a failure that is not a clean end alone, however long it served", async t => {
    let harness = makeHarness(~staleTimeout=60_000)

    let driver = harness->driverAt(0)
    driver.onConnected()
    await Vi.advanceTimersByTimeAsync(30_000)
    // Staleness and errors are named after what happened, so only an end with
    // nothing wrong with it can become a rotation.
    driver.onFailure(~reason=Source.TransportError)
    harness.unsubscribe()

    t.expect(harness.statuses).toStrictEqual(["live", "down:error"])
  })

  Async.it("Trims a failure detail that would flood the log", async t => {
    let harness = makeHarness()
    (harness->driverAt(0)).onFailure(~reason=Source.SubscribeRejected, ~detail=String.repeat("y", 500))

    await Vi.advanceTimersByTimeAsync(250)
    harness.unsubscribe()

    t.expect(harness.statuses).toStrictEqual([
      `down:subscribe-rejected:${String.repeat("y", 200)}...`,
    ])
  })

  Async.it("Counts a socket that errors and then closes as one failure", async t => {
    let harness = makeHarness()
    let driver = harness->driverAt(0)
    driver.onConnected()
    driver.onFailure(~reason=Source.TransportError)
    driver.onFailure(~reason=Source.Closed)

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
    // Carried out to the consumer's log: the reason alone can't say which field
    // of which frame a provider got wrong.
    driver.onUnreadable(~detail=`{"height":"not-a-number"}`)

    // Keep-alives stop holding the connection open once something unreadable
    // has arrived: on a stream whose heights are all malformed, the pings
    // between them are the only other traffic, and they would otherwise keep it
    // alive forever without it ever reporting anything.
    await Vi.advanceTimersByTimeAsync(14_000)
    driver.onKeepAlive()
    await Vi.advanceTimersByTimeAsync(1_000)
    await Vi.advanceTimersByTimeAsync(250)

    // A height read off the same connection says the shape is fine after all,
    // so one stray message must not go on naming later failures.
    let reconnected = harness->driverAt(1)
    reconnected.onConnected()
    reconnected.onUnreadable(~detail="garbled")
    reconnected.onHeight(101)
    await Vi.advanceTimersByTimeAsync(15_000)
    harness.unsubscribe()

    t.expect((harness.statuses, harness.heights)).toStrictEqual((
      [
        "live",
        `down:unreadable:{"height":"not-a-number"}`,
        "live",
        "down:stale",
      ],
      [101],
    ))
  })

  Async.it("Trims an unreadable frame that would flood the log", async t => {
    let harness = makeHarness()
    let driver = harness->driverAt(0)
    driver.onConnected()
    driver.onUnreadable(~detail=String.repeat("x", 500))

    await Vi.advanceTimersByTimeAsync(15_000)
    harness.unsubscribe()

    t.expect(harness.statuses).toStrictEqual([
      "live",
      `down:unreadable:${String.repeat("x", 200)}...`,
    ])
  })

  Async.it("Treats a delivered height as proof the stream is live", async t => {
    let harness = makeHarness()
    let driver = harness->driverAt(0)

    // A transport that delivers heights without ever reporting the connection
    // usable would otherwise leave its consumer polling at full rate for the
    // life of the process, next to a stream that works.
    driver.onHeight(101)
    driver.onHeight(102)
    harness.unsubscribe()

    t.expect((harness.statuses, harness.heights)).toStrictEqual((["live"], [101, 102]))
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

  Async.it("Retries even when closing the failed connection throws", async t => {
    let harness = makeHarness(~throwOnClose=true)
    let driver = harness->driverAt(0)
    driver.onConnected()
    driver.onFailure(~reason=Source.Closed)

    await Vi.advanceTimersByTimeAsync(250)
    harness.unsubscribe()

    t.expect((harness.drivers->Array.length, harness.statuses)).toStrictEqual((
      2,
      ["live", "down:closed"],
    ))
  })

  Async.it("Survives a throwing close on a connection superseded during connect", async t => {
    // connect fails before it returns, so its socket is already superseded by
    // the time the driver gets the close function back. start() runs from the
    // retry timer, so a throw on that path is an uncaught exception.
    let harness = makeHarness(~failOnConnect=Source.Closed, ~throwOnClose=true)

    await Vi.advanceTimersByTimeAsync(250)
    harness.unsubscribe()

    t.expect((harness.drivers->Array.length, harness.statuses)).toStrictEqual((
      2,
      ["down:closed", "down:closed"],
    ))
  })

  Async.it("Ignores everything a connection reports after unsubscribing", async t => {
    let harness = makeHarness()
    let driver = harness->driverAt(0)
    driver.onConnected()
    harness.unsubscribe()

    driver.onHeight(7)
    driver.onFailure(~reason=Source.Closed)
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
      connectsAroundRetry->Array.push(await harness->advanceThroughRetryWindow(~delay=250))->ignore
    }
    harness.unsubscribe()

    t.expect(connectsAroundRetry).toStrictEqual([(1, 2), (2, 3), (3, 4), (4, 5)])
  })

  Async.it("Keeps retrying when the transport throws while connecting", async t => {
    // Reached through a malformed url: escaping the retry timer would take the
    // process down instead.
    let harness = makeHarness(~throwOnConnect=true)

    let (beforeRetry, afterRetry) = await harness->advanceThroughRetryWindow(~delay=250)
    harness.unsubscribe()

    t.expect((beforeRetry, afterRetry, harness.statuses)).toStrictEqual((
      1,
      2,
      ["down:connect-failed", "down:connect-failed"],
    ))
  })

  Async.it("Retries rather than waits for staleness when connect fails immediately", async t => {
    let harness = makeHarness(~failOnConnect=Source.Http(401))

    let (beforeRetry, afterRetry) = await harness->advanceThroughRetryWindow(~delay=250)
    harness.unsubscribe()

    t.expect((beforeRetry, afterRetry, harness.statuses)).toStrictEqual((
      1,
      2,
      ["down:http-401", "down:http-401"],
    ))
  })
})

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

let listenHttp = handler => {
  let server = MockRpcServer.createServer(handler)
  Promise.make((resolve, _reject) =>
    server->MockRpcServer.listenOnHost(0, "127.0.0.1", () =>
      resolve((server, `http://127.0.0.1:${(server->MockRpcServer.address).port->Int.toString}`))
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

describe("HyperSyncSSE", () => {
  Async.it("Reports the HTTP status as the failure reason", async t => {
    let (server, url) = await listenHttp((_request, response) => {
      response->MockRpcServer.writeHead(401, Dict.fromArray([("Content-Type", "text/plain")]))
      response->MockRpcServer.end_("unauthorized")
    })
    let statuses = []
    // The status alone can't tell an operator which of a provider's many 401s
    // this was, so the transport has to carry its message out too.
    let detailed = []
    let unsubscribe = HyperSyncSSE.subscribe(
      ~hyperSyncUrl=url,
      ~apiToken="bad-token",
      ~onHeight=_ => (),
      ~onStatus=status => {
        statuses->Array.push(status->reasonLabel)->ignore
        switch status {
        | Down(down) => detailed->Array.push(down.detail->Option.isSome)->ignore
        | Live => ()
        }
      },
    )

    await Scenario.waitUntil(() => statuses->Array.length > 0, ~message="the height stream")
    unsubscribe()
    await Promise.make((resolve, _reject) => server->MockRpcServer.close(() => resolve()))

    t.expect((statuses, detailed)).toStrictEqual((["down:http-401"], [true]))
  })

  Async.it("Delivers heights and reports a clean stream end as closed", async t => {
    let (server, url) = await listenHttp((_request, response) => {
      response->MockRpcServer.writeHead(
        200,
        Dict.fromArray([("Content-Type", "text/event-stream"), ("Cache-Control", "no-cache")]),
      )
      response->MockRpcServer.write("event: height\ndata: 123\n\n")
      // Ending the response drops the stream without an HTTP error, which is
      // how a load balancer rotating connections shows up.
      response->MockRpcServer.endStream()
    })
    let statuses = []
    let heights = []
    let unsubscribe = HyperSyncSSE.subscribe(
      ~hyperSyncUrl=url,
      ~apiToken="test-token",
      ~onHeight=height => heights->Array.push(height)->ignore,
      ~onStatus=status => statuses->Array.push(status->reasonLabel)->ignore,
    )

    await Scenario.waitUntil(
      () => statuses->Array.includes("down:closed"),
      ~message="the height stream",
    )
    unsubscribe()
    await Promise.make((resolve, _reject) => server->MockRpcServer.close(() => resolve()))

    t.expect((statuses, heights)).toStrictEqual((["live", "down:closed"], [123]))
  })
})

describe("EvmRpcWs", () => {
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
    let unsubscribe = EvmRpcWs.subscribe(
      ~wsUrl=url,
      ~onHeight=height => heights->Array.push(height)->ignore,
      ~onStatus=status => statuses->Array.push(status->reasonLabel)->ignore,
    )

    await Scenario.waitUntil(() => heights->Array.length > 0, ~message="the height stream")
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
    let unsubscribe = EvmRpcWs.subscribe(
      ~wsUrl=url,
      ~onHeight=_ => (),
      ~onStatus=status => statuses->Array.push(status->reasonLabel)->ignore,
    )

    await Utils.delay(200)
    unsubscribe()
    await Promise.make((resolve, _reject) => server->WsServer.close(() => resolve()))

    t.expect(statuses).toStrictEqual([])
  })

  Async.it("Treats a frame it cannot make sense of as unreadable, not as a rejection", async t => {
    // Valid JSON, but none of the shapes this stream knows. Reporting it as a
    // rejected subscription would name a cause the provider never gave.
    let (server, url) = await listenWs(socket =>
      socket->WsServer.onMessage(_data =>
        socket->WsServer.send(`{"jsonrpc":"2.0","hello":"world"}`)
      )
    )
    let statuses = []
    let unsubscribe = EvmRpcWs.subscribe(
      ~wsUrl=url,
      ~onHeight=_ => (),
      ~onStatus=status => statuses->Array.push(status->reasonLabel)->ignore,
    )

    await Utils.delay(200)
    unsubscribe()
    await Promise.make((resolve, _reject) => server->WsServer.close(() => resolve()))

    t.expect(statuses).toStrictEqual([])
  })

  Async.it("Keeps a delivering connection through an error meant for something else", async t => {
    let (server, url) = await listenWs(socket =>
      socket->WsServer.onMessage(data =>
        if data->WsServer.toString->String.includes("eth_subscribe") {
          socket->WsServer.send(`{"jsonrpc":"2.0","id":1,"result":"0xsub"}`)
          // Nothing to do with the subscription this stream asked for: a
          // provider talking about some other request, or about itself.
          socket->WsServer.send(
            `{"jsonrpc":"2.0","id":7,"error":{"code":-32005,"message":"rate limited"}}`,
          )
          socket->WsServer.send(
            `{"jsonrpc":"2.0","method":"eth_subscription","params":{"subscription":"0xsub","result":{"number":"0x2a"}}}`,
          )
        }
      )
    )
    let statuses = []
    let heights = []
    let unsubscribe = EvmRpcWs.subscribe(
      ~wsUrl=url,
      ~onHeight=height => heights->Array.push(height)->ignore,
      ~onStatus=status => statuses->Array.push(status->reasonLabel)->ignore,
    )

    await Scenario.waitUntil(() => heights->Array.length > 0, ~message="the height stream")
    unsubscribe()
    await Promise.make((resolve, _reject) => server->WsServer.close(() => resolve()))

    t.expect((statuses, heights)).toStrictEqual((["live"], [42]))
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
    let unsubscribe = EvmRpcWs.subscribe(
      ~wsUrl=url,
      ~onHeight=_ => (),
      ~onStatus=status => statuses->Array.push(status->reasonLabel)->ignore,
    )

    // Long enough for the first retry to reconnect and be rejected again.
    await Scenario.waitUntil(() => statuses->Array.length > 1, ~message="the height stream")
    unsubscribe()
    await Promise.make((resolve, _reject) => server->WsServer.close(() => resolve()))

    t.expect(statuses).toStrictEqual(["down:subscribe-rejected", "down:subscribe-rejected"])
  })

  Async.it("Reports a rejection the provider answered with a null id", async t => {
    // JSON-RPC answers a request it could not parse with an explicit null id.
    // The subscribe is the only request this socket ever sends, so an error
    // naming no id is still that subscription being refused.
    let (server, url) = await listenWs(
      socket =>
        socket->WsServer.onMessage(
          _data =>
            socket->WsServer.send(`{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"parse error"}}`),
        ),
    )
    let statuses = []
    let unsubscribe = EvmRpcWs.subscribe(
      ~wsUrl=url,
      ~onHeight=_ => (),
      ~onStatus=status => statuses->Array.push(status->reasonLabel)->ignore,
    )

    await Scenario.waitUntil(() => statuses->Array.length > 1, ~message="the height stream")
    unsubscribe()
    await Promise.make((resolve, _reject) => server->WsServer.close(() => resolve()))

    t.expect(statuses).toStrictEqual(["down:subscribe-rejected", "down:subscribe-rejected"])
  })

  Async.it("Reads a subscription whose id the provider echoed as a string", async t => {
    // JSON-RPC ids are any scalar, and gateways do echo an int id back as a
    // string. Failing to match one costs the whole stale window before the
    // rejection is reported, under a reason the provider never gave.
    let (server, url) = await listenWs(
      socket =>
        socket->WsServer.onMessage(
          _data =>
            socket->WsServer.send(`{"jsonrpc":"2.0","id":"1","error":{"code":-32601,"message":"not supported"}}`),
        ),
    )
    let statuses = []
    let unsubscribe = EvmRpcWs.subscribe(
      ~wsUrl=url,
      ~onHeight=_ => (),
      ~onStatus=status => statuses->Array.push(status->reasonLabel)->ignore,
    )

    await Scenario.waitUntil(() => statuses->Array.length > 1, ~message="the height stream")
    unsubscribe()
    await Promise.make((resolve, _reject) => server->WsServer.close(() => resolve()))

    t.expect(statuses).toStrictEqual(["down:subscribe-rejected", "down:subscribe-rejected"])
  })

  Async.it("Confirms a subscription whose id came back as a string", async t => {
    let (server, url) = await listenWs(
      socket =>
        socket->WsServer.onMessage(
          data =>
            if data->WsServer.toString->String.includes("eth_subscribe") {
              socket->WsServer.send(`{"jsonrpc":"2.0","id":"1","result":"0xsub"}`)
              socket->WsServer.send(`{"jsonrpc":"2.0","method":"eth_subscription","params":{"subscription":"0xsub","result":{"number":"0x2a"}}}`)
            },
        ),
    )
    let statuses = []
    let heights = []
    let unsubscribe = EvmRpcWs.subscribe(
      ~wsUrl=url,
      ~onHeight=height => heights->Array.push(height)->ignore,
      ~onStatus=status => statuses->Array.push(status->reasonLabel)->ignore,
    )

    await Scenario.waitUntil(() => heights->Array.length > 0, ~message="the height stream")
    unsubscribe()
    await Promise.make((resolve, _reject) => server->WsServer.close(() => resolve()))

    t.expect((statuses, heights)).toStrictEqual((["live"], [42]))
  })

  Async.it("Ignores a success frame that answers no request this socket made", async t => {
    // A stray success frame is not the subscribe being confirmed, and taking it
    // for one reports a stream that is live while nothing was ever subscribed.
    let (server, url) = await listenWs(
      socket =>
        socket->WsServer.onMessage(
          _data => socket->WsServer.send(`{"jsonrpc":"2.0","id":7,"result":"0xsomethingelse"}`),
        ),
    )
    let statuses = []
    let unsubscribe = EvmRpcWs.subscribe(
      ~wsUrl=url,
      ~onHeight=_ => (),
      ~onStatus=status => statuses->Array.push(status->reasonLabel)->ignore,
    )

    await Utils.delay(200)
    unsubscribe()
    await Promise.make((resolve, _reject) => server->WsServer.close(() => resolve()))

    t.expect(statuses).toStrictEqual([])
  })
})
