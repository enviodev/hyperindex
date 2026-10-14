open Vitest

// How long the indexer takes to get calls to its sidecar (T-016):
// `envio_sidecar_delivery_seconds{kind,outcome}` per POST and
// `envio_sidecar_commit_to_ack_seconds` from the commit to the sidecar's 202.

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
name: sidecar-latency
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

// Each histogram's count, by its rendered labels.
let counts = (stats: SidecarSender.stats) => (
  stats.deliverySeconds
  ->Dict.toArray
  ->Array.map(((labels, h)) => (labels, h.count))
  ->Array.toSorted(((a, _), (b, _)) => String.compare(a, b)),
  stats.commitToAckSeconds.count,
)

let histogram = (buckets, values) => {
  let h = SidecarSender.makeHistogram(buckets)
  values->Array.forEach(value => h->SidecarSender.observe(value))
  h
}

let stats = (~deliverySeconds=Dict.make(), ~commitToAck=[]): SidecarSender.stats => {
  queued: 0,
  sent: 0,
  rollbacksSent: 0,
  dropped: Dict.make(),
  up: None,
  lastAckSeconds: None,
  queueMax: 10_000,
  deliverySeconds,
  commitToAckSeconds: histogram(SidecarSender.commitToAckBuckets, commitToAck),
}

let withSidecar = sidecar => {...TestChainMetrics.emptySnapshot, sidecar: Some(sidecar)}

let familyLines = (text, name) =>
  text->String.split("\n")->Array.filter(line => line->String.includes(name))

describe("Sidecar delivery latency", () => {
  Async.it("times every POST by kind and outcome, and each call from commit to ack", async t => {
    let failures = ref(1)
    let sidecar = await FakeSidecar.start(
      ~respond=async request =>
        switch request.path {
        | "/envio/calls" if failures.contents > 0 =>
          failures := failures.contents - 1
          {FakeSidecar.status: 503, body: {"status": "closing"}->toJson}
        | _ => await FakeSidecar.runtimeReply(request)
        },
    )
    let sender = SidecarSender.make(~url=sidecar.url, ~backoffBaseMs=5, ~backoffCapMs=20)
    sender->SidecarSender.enqueueCommitted(~rollbackTargets=[], ~calls=[call(1), call(2)])
    sender->SidecarSender.enqueueCommitted(
      ~rollbackTargets=[{chainId: ChainId.fromInt(1337), rollbackToBlock: 1}],
      ~calls=[call(2)],
    )
    await sender->SidecarSender.flush(~timeoutMs=2_000)
    sender->SidecarSender.stop
    await sidecar.close()

    t.expect(sender->SidecarSender.stats->counts).toEqual((
      [
        (`kind="calls",outcome="delivered"`, 2),
        (`kind="calls",outcome="retry"`, 1),
        (`kind="rollback",outcome="delivered"`, 1),
      ],
      // Call 1, then the replayed 2: the rollback took the first 2 out of
      // the batch being retried, and a dropped call is never acked.
      2,
    ))
  })

  Async.it("times a refused batch and does not count its calls as acked", async t => {
    let sidecar = await FakeSidecar.start(
      ~respond=async _ => {
        FakeSidecar.status: 400,
        body: {"error": "contract"}->toJson,
      },
    )
    let sender = SidecarSender.make(~url=sidecar.url)
    sender->SidecarSender.enqueueCommitted(~rollbackTargets=[], ~calls=[call(1)])
    await sender->SidecarSender.flush(~timeoutMs=2_000)
    sender->SidecarSender.stop
    await sidecar.close()

    t.expect(sender->SidecarSender.stats->counts).toEqual((
      [(`kind="calls",outcome="refused"`, 1)],
      0,
    ))
  })

  Async.it("shows on the indexer's /metrics after a real delivery", async t => {
    let sidecar = await FakeSidecar.start()
    let sender = SidecarSender.make(~url=sidecar.url)
    let samples = ref(None)
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
        samples :=
          Some((
            await indexer.metric("envio_sidecar_delivery_seconds_count"),
            await indexer.metric("envio_sidecar_commit_to_ack_seconds_count"),
            (await indexer.metric("envio_sidecar_commit_to_ack_seconds_bucket"))->Array.length,
          ))
      },
    )
    sender->SidecarSender.stop
    await sidecar.close()

    t.expect(samples.contents).toEqual(
      Some((
        [
          {
            IndexerRunner.value: "1",
            labels: dict{"kind": "calls", "outcome": "delivered"},
          },
        ],
        [{value: "1", labels: Dict.make()}],
        SidecarSender.commitToAckBuckets->Array.length + 1,
      )),
    )
  })

  it("Renders cumulative buckets, sum and count", t => {
    let text = Metrics.collect(
      ~metrics=Some(
        withSidecar(
          stats(
            ~deliverySeconds=Dict.fromArray([
              (
                `kind="calls",outcome="delivered"`,
                histogram(SidecarSender.deliveryBuckets, [0.004, 0.02, 0.0201, 40.]),
              ),
            ]),
            ~commitToAck=[0.3],
          ),
        ),
      ),
    )

    t.expect((
      text->familyLines("envio_sidecar_delivery_seconds"),
      text->familyLines("envio_sidecar_commit_to_ack_seconds")->Array.slice(~start=0, ~end=4),
      text->familyLines("envio_sidecar_commit_to_ack_seconds")->Array.slice(~start=-2),
    )).toEqual((
      [
        "# HELP envio_sidecar_delivery_seconds How long one POST to the sidecar took until its answer, by kind (calls, rollback) and outcome (delivered; retry: refused connection, timeout, 5xx or 429, sent again; refused: any other 4xx, dropped).",
        "# TYPE envio_sidecar_delivery_seconds histogram",
        `envio_sidecar_delivery_seconds_bucket{kind="calls",outcome="delivered",le="0.005"} 1`,
        `envio_sidecar_delivery_seconds_bucket{kind="calls",outcome="delivered",le="0.01"} 1`,
        `envio_sidecar_delivery_seconds_bucket{kind="calls",outcome="delivered",le="0.025"} 3`,
        `envio_sidecar_delivery_seconds_bucket{kind="calls",outcome="delivered",le="0.05"} 3`,
        `envio_sidecar_delivery_seconds_bucket{kind="calls",outcome="delivered",le="0.1"} 3`,
        `envio_sidecar_delivery_seconds_bucket{kind="calls",outcome="delivered",le="0.25"} 3`,
        `envio_sidecar_delivery_seconds_bucket{kind="calls",outcome="delivered",le="0.5"} 3`,
        `envio_sidecar_delivery_seconds_bucket{kind="calls",outcome="delivered",le="1"} 3`,
        `envio_sidecar_delivery_seconds_bucket{kind="calls",outcome="delivered",le="2.5"} 3`,
        `envio_sidecar_delivery_seconds_bucket{kind="calls",outcome="delivered",le="5"} 3`,
        `envio_sidecar_delivery_seconds_bucket{kind="calls",outcome="delivered",le="10"} 3`,
        `envio_sidecar_delivery_seconds_bucket{kind="calls",outcome="delivered",le="30"} 3`,
        `envio_sidecar_delivery_seconds_bucket{kind="calls",outcome="delivered",le="+Inf"} 4`,
        `envio_sidecar_delivery_seconds_sum{kind="calls",outcome="delivered"} 40.0441`,
        `envio_sidecar_delivery_seconds_count{kind="calls",outcome="delivered"} 4`,
      ],
      [
        "# HELP envio_sidecar_commit_to_ack_seconds From the write that committed a sidecar call to the sidecar accepting it, queueing and retries included.",
        "# TYPE envio_sidecar_commit_to_ack_seconds histogram",
        `envio_sidecar_commit_to_ack_seconds_bucket{le="0.01"} 0`,
        `envio_sidecar_commit_to_ack_seconds_bucket{le="0.05"} 0`,
      ],
      [
        `envio_sidecar_commit_to_ack_seconds_sum 0.3`,
        `envio_sidecar_commit_to_ack_seconds_count 1`,
      ],
    ))
  })

  it("Merges workers' histograms bucket by bucket", t => {
    let key = `kind="calls",outcome="delivered"`
    let merged =
      Metrics.merge(
        [
          withSidecar(
            stats(
              ~deliverySeconds=Dict.fromArray([
                (key, histogram(SidecarSender.deliveryBuckets, [0.001])),
              ]),
              ~commitToAck=[0.02],
            ),
          ),
          withSidecar(
            stats(
              ~deliverySeconds=Dict.fromArray([
                (key, histogram(SidecarSender.deliveryBuckets, [0.001, 100.])),
                (
                  `kind="rollback",outcome="delivered"`,
                  histogram(SidecarSender.deliveryBuckets, [0.2]),
                ),
              ]),
              ~commitToAck=[400.],
            ),
          ),
        ],
        ~startTime=Date.make(),
        ~metricTime=Date.make(),
        ~elapsedSeconds=0.,
        ~targetBufferSize=0,
      ).sidecar->Option.map(
        s => (
          s.deliverySeconds->Dict.get(key)->Option.map(h => (h.counts, h.count)),
          s->counts,
          s.commitToAckSeconds.counts,
        ),
      )

    t.expect(merged).toEqual(
      Some((
        Some(([2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1], 3)),
        ([(key, 3), (`kind="rollback",outcome="delivered"`, 1)], 2),
        [0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1],
      )),
    )
  })
})
