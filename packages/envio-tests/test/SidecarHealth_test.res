open Vitest

// Whether the indexer can reach its sidecar, and the sidecar's own numbers on
// the indexer's /metrics (D-008 items 3 and 4, wiki/09-reliability.md 2 and 5).

@module("envio") external defineSidecar: {..} => unknown = "defineSidecar"

let contract = defineSidecar({"functions": {"ping": {"input": {"n": S.int}}}})
contract->(Utils.magic: unknown => SidecarContract.t)->SidecarContract.set

type sidecarCaller = {ping: {"n": int} => string}
type handlerContext = {sidecar: sidecarCaller}

let ping = (blockNumber): MockSource.itemMock => {
  blockNumber,
  logIndex: 0,
  handler: async args => {
    let context = args.context->(Utils.magic: Internal.handlerContext => handlerContext)
    let _ = context.sidecar.ping({"n": blockNumber})
  },
}

let scenario = Scenario.make(
  ~supervised=false,
  ~configYaml=`
name: sidecar-health
rollback_on_reorg: true
contracts:
  - name: Gravatar
    events:
      - event: "TestEvent()"
chains:
  - id: 1337
    rpc:
      url: https://rpc1337.example.test
      for: sync
    start_block: 1
    contracts:
      - name: Gravatar
        address: "0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3"
`,
)

let methods: array<MockSource.method> = [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes]
let sources: array<Scenario.sourceMock> = [{chain: 1337, methods}]

let toJson = (value: {..}) => value->(Utils.magic: {..} => JSON.t)

let call = (blockNumber): SidecarCall.t => {
  id: `1337:${blockNumber->Int.toString}:0r0:0`,
  fn: "ping",
  chainId: ChainId.fromInt(1337),
  blockNumber,
  blockTimestamp: Some(blockNumber),
  checkpointId: blockNumber->BigInt.fromInt,
  input: {"n": blockNumber}->toJson,
}

let deliver = (sender, blockNumber) =>
  sender->SidecarSender.enqueueCommitted(~rollbackTargets=[], ~calls=[call(blockNumber)])

let isUp = (sender, expected) => () => (sender->SidecarSender.stats).up === Some(expected)

// The runtime's /readyz: 200 when ready, 503 with its state otherwise.
let readyz = (state: ref<string>) =>
  async (request: FakeSidecar.request) =>
    switch request.path {
    | "/readyz" =>
      state.contents === "ready"
        ? {FakeSidecar.status: 200, body: {"status": "ready"}->toJson}
        : {status: 503, body: {"status": state.contents}->toJson}
    | _ => await FakeSidecar.runtimeReply(request)
    }

describe("Sidecar reachability", () => {
  Async.it("reports the sidecar up, its last ack and the queue bound after a delivery", async t => {
    let sidecar = await FakeSidecar.start()
    let sender = SidecarSender.make(~url=sidecar.url)
    let before = Date.now() /. 1000.
    let metrics = ref(None)
    await scenario->Scenario.run(
      ~sources,
      ~reorgThresholdReadyTolerance=0,
      ~sidecarSender=sender,
      async (~indexer, ~source) => {
        let source = source(1337)
        await Scenario.enterReorgThreshold(~t, ~indexer, ~source)
        source.resolveGetItemsOrThrow([ping(101)], ~latestFetchedBlockNumber=101)
        await indexer.getBatchWritePromise()
        await Scenario.waitUntil(
          () => (sender->SidecarSender.stats).sent > 0,
          ~message="the call to be acknowledged",
        )
        metrics :=
          Some((
            await indexer.metric("envio_sidecar_up"),
            await indexer.metric("envio_sidecar_queue_max"),
            await indexer.metric("envio_sidecar_last_ack_timestamp_seconds"),
          ))
      },
    )
    sender->SidecarSender.stop
    await sidecar.close()
    let after = Date.now() /. 1000.

    let ackedInRun = (samples: array<IndexerRunner.metric>) =>
      samples->Array.map(
        sample =>
          switch sample.value->Float.fromString {
          | Some(seconds) => seconds >= before -. 0.001 && seconds <= after +. 0.001
          | None => false
          },
      )
    t.expect(
      metrics.contents->Option.map(
        ((up, queueMax, lastAck)) => (up, queueMax, lastAck->ackedInRun),
      ),
    ).toEqual(
      Some((
        [{IndexerRunner.value: "1", labels: Dict.make()}],
        [{value: "10000", labels: Dict.make()}],
        [true],
      )),
    )
  })

  Async.it("is down while the sidecar refuses connections", async t => {
    let url = await FakeSidecar.down()
    let sender = SidecarSender.make(~url, ~backoffBaseMs=1, ~backoffCapMs=5)
    let beforeAnyAnswer = (sender->SidecarSender.stats).up
    sender->deliver(101)
    await Scenario.waitUntil(sender->isUp(false), ~message="the sender to see the sidecar down")
    let stats = sender->SidecarSender.stats
    sender->SidecarSender.stop

    t.expect((beforeAnyAnswer, stats.up, stats.lastAckSeconds, stats.sent)).toEqual((
      None,
      Some(false),
      None,
      0,
    ))
  })

  Async.it("goes down on the first failed attempt and up again on the next success", async t => {
    let failing = ref(true)
    let sidecar = await FakeSidecar.start(
      ~respond=async request =>
        failing.contents
          ? {FakeSidecar.status: 503, body: {"error": "closing"}->toJson}
          : await FakeSidecar.runtimeReply(request),
    )
    let sender = SidecarSender.make(~url=sidecar.url, ~backoffBaseMs=5, ~backoffCapMs=20)
    sender->deliver(101)
    await Scenario.waitUntil(sender->isUp(false), ~message="the 503 to mark the sidecar down")
    failing := false
    await Scenario.waitUntil(
      () => (sender->SidecarSender.stats).sent === 1,
      ~message="the retried call to be acknowledged",
    )
    let stats = sender->SidecarSender.stats
    sender->SidecarSender.stop
    await sidecar.close()

    t.expect((stats.up, stats.lastAckSeconds->Option.isSome)).toEqual((Some(true), true))
  })

  Async.it("checks /readyz while idle, a 503 starting or closing counting as down", async t => {
    let state = ref("starting")
    let sidecar = await FakeSidecar.start(~respond=readyz(state))
    let sender = SidecarSender.make(~url=sidecar.url, ~probeMs=10)
    await Scenario.waitUntil(sender->isUp(false), ~message="a starting sidecar to read as down")
    state := "ready"
    await Scenario.waitUntil(sender->isUp(true), ~message="a ready sidecar to read as up")
    state := "closing"
    await Scenario.waitUntil(sender->isUp(false), ~message="a closing sidecar to read as down")
    sender->SidecarSender.stop
    await sidecar.close()

    t.expect(
      (
        sidecar.requests->Array.every(request => request.path === "/readyz"),
        (sender->SidecarSender.stats).lastAckSeconds,
      ),
      ~message="an idle sender only probes, and a probe is not an ack",
    ).toEqual((true, None))
  })

  Async.it("reads an idle sidecar that is not listening as down", async t => {
    let url = await FakeSidecar.down()
    let sender = SidecarSender.make(~url, ~probeMs=10)
    await Scenario.waitUntil(sender->isUp(false), ~message="the probe to fail")
    sender->SidecarSender.stop
    t.expect((sender->SidecarSender.stats).up).toEqual(Some(false))
  })

  Async.it("stops probing once stopped", async t => {
    let state = ref("ready")
    let sidecar = await FakeSidecar.start(~respond=readyz(state))
    let sender = SidecarSender.make(~url=sidecar.url, ~probeMs=10)
    await Scenario.waitUntil(sender->isUp(true), ~message="the first probe")
    sender->SidecarSender.stop
    await Utils.delay(30)
    let count = sidecar.requests->Array.length
    await Utils.delay(60)
    await sidecar.close()

    t.expect(sidecar.requests->Array.length).toBe(count)
  })
})

let stats = (~up=?, ~lastAckSeconds=?, ~queueMax=10_000): SidecarSender.stats => {
  queued: 0,
  sent: 0,
  rollbacksSent: 0,
  dropped: Dict.make(),
  up,
  lastAckSeconds,
  queueMax,
  deliverySeconds: Dict.make(),
  commitToAckSeconds: SidecarSender.makeHistogram(SidecarSender.commitToAckBuckets),
}

let withSidecar = sidecar => {...TestChainMetrics.emptySnapshot, sidecar: Some(sidecar)}

let sidecarLines = text =>
  text
  ->String.split("\n")
  ->Array.filter(line =>
    line->String.includes("envio_sidecar_up") ||
    line->String.includes("envio_sidecar_queue_max") ||
    line->String.includes("envio_sidecar_last_ack")
  )

describe("Sidecar reachability metrics", () => {
  it("Renders the queue bound always, up and last ack only once known", t => {
    let unknown = Metrics.collect(~metrics=Some(withSidecar(stats())))
    let known = Metrics.collect(
      ~metrics=Some(withSidecar(stats(~up=false, ~lastAckSeconds=1760400000.25))),
    )

    t.expect((unknown->sidecarLines, known->sidecarLines)).toEqual((
      [
        "# HELP envio_sidecar_queue_max The most sidecar calls the queue holds before dropping the oldest (ENVIO_SIDECAR_QUEUE_MAX).",
        "# TYPE envio_sidecar_queue_max gauge",
        "envio_sidecar_queue_max 10000",
      ],
      [
        "# HELP envio_sidecar_queue_max The most sidecar calls the queue holds before dropping the oldest (ENVIO_SIDECAR_QUEUE_MAX).",
        "# TYPE envio_sidecar_queue_max gauge",
        "envio_sidecar_queue_max 10000",
        "# HELP envio_sidecar_up 1 when the sidecar's last answer to a delivery or readiness check was a success, 0 when it failed.",
        "# TYPE envio_sidecar_up gauge",
        "envio_sidecar_up 0",
        "# HELP envio_sidecar_last_ack_timestamp_seconds Unix time the sidecar last accepted a POST of calls or a rollback notice.",
        "# TYPE envio_sidecar_last_ack_timestamp_seconds gauge",
        "envio_sidecar_last_ack_timestamp_seconds 1760400000.25",
      ],
    ))
  })

  it("Merges workers: up while any can reach it, the latest ack, the bounds added up", t => {
    let merge = sidecars =>
      switch Metrics.merge(
        sidecars->Array.map(withSidecar),
        ~startTime=Date.make(),
        ~metricTime=Date.make(),
        ~elapsedSeconds=0.,
        ~targetBufferSize=0,
      ).sidecar {
      | Some(s) => Some((s.up, s.lastAckSeconds, s.queueMax))
      | None => None
      }

    t.expect((
      merge([stats(~up=false, ~lastAckSeconds=5.), stats(~up=true, ~lastAckSeconds=3.)]),
      merge([stats(~up=false), stats()]),
      merge([stats(), stats(~queueMax=5)]),
    )).toEqual((
      Some((Some(true), Some(5.), 20_000)),
      Some((Some(false), None, 20_000)),
      Some((None, None, 10_005)),
    ))
  })

  it("Appends another exposition, leaving out a family the indexer already renders", t => {
    let own = `# HELP envio_info Information about the indexer
# TYPE envio_info gauge
envio_info{version="1"} 1
`
    let sidecar = `# HELP envio_info A clash.
# TYPE envio_info gauge
envio_info 2

# HELP envio_sidecar_ready Ready.
# TYPE envio_sidecar_ready gauge
envio_sidecar_ready 1
`

    t.expect((
      Metrics.appendExposition(own, sidecar),
      Metrics.appendExposition(own, "\n"),
    )).toEqual((
      own ++ `
# HELP envio_sidecar_ready Ready.
# TYPE envio_sidecar_ready gauge
envio_sidecar_ready 1
`,
      own,
    ))
  })
})

let sidecarExposition = `# HELP envio_sidecar_function_calls_total Calls by function and outcome.
# TYPE envio_sidecar_function_calls_total counter
envio_sidecar_function_calls_total{fn="ping",outcome="succeeded"} 3
# HELP envio_sidecar_ready 1 when the sidecar takes calls.
# TYPE envio_sidecar_ready gauge
envio_sidecar_ready 1
`

let servingMetrics = (~delayMs=0, ~status=200) =>
  async (request: FakeSidecar.request) =>
    switch request.path {
    | "/metrics" =>
      await Utils.delay(delayMs)
      {FakeSidecar.status, body: JSON.Null, text: sidecarExposition}
    | _ => await FakeSidecar.runtimeReply(request)
    }

describe("The indexer's /metrics with a sidecar", () => {
  Async.it("Appends the sidecar's own metrics after the indexer's", async t => {
    let sidecar = await FakeSidecar.start(~respond=servingMetrics())
    let metrics = Some(withSidecar(stats(~up=true)))
    let body = await Server.collectMetrics(~metrics, ~sidecarUrl=sidecar.url)
    await sidecar.close()

    t.expect(body).toBe(Metrics.collect(~metrics) ++ "\n" ++ sidecarExposition)
  })

  Async.it("Serves the indexer's alone when the sidecar does not answer", async t => {
    let url = await FakeSidecar.down()
    let metrics = Some(withSidecar(stats(~up=false)))
    t.expect(await Server.collectMetrics(~metrics, ~sidecarUrl=url)).toBe(Metrics.collect(~metrics))
  })

  Async.it("Serves the indexer's alone when the sidecar answers late or with an error", async t => {
    let slow = await FakeSidecar.start(~respond=servingMetrics(~delayMs=1_500))
    let failing = await FakeSidecar.start(~respond=servingMetrics(~status=500))
    let metrics = Some(withSidecar(stats(~up=true)))
    let started = Date.now()
    let late = await Server.collectMetrics(~metrics, ~sidecarUrl=slow.url)
    let tookMs = Date.now() -. started
    let errored = await Server.collectMetrics(~metrics, ~sidecarUrl=failing.url)
    await slow.close()
    await failing.close()

    t.expect((late, errored, tookMs < 1_400.)).toEqual((
      Metrics.collect(~metrics),
      Metrics.collect(~metrics),
      true,
    ))
  })

  Async.it("Does not ask for the sidecar's when the indexer has none", async t => {
    let sidecar = await FakeSidecar.start(~respond=servingMetrics())
    let metrics = Some(TestChainMetrics.emptySnapshot)
    let body = await Server.collectMetrics(~metrics, ~sidecarUrl=sidecar.url)
    let noState = await Server.collectMetrics(~metrics=None, ~sidecarUrl=sidecar.url)
    await sidecar.close()

    t.expect((body, noState, sidecar.requests->Array.length)).toEqual((
      Metrics.collect(~metrics),
      Metrics.collect(~metrics=None),
      0,
    ))
  })
})
