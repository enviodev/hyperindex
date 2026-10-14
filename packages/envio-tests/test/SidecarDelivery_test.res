open Vitest

// After a batch commits, its `context.sidecar` calls go to the sidecar's
// internal server, and a rollback notice goes ahead of the calls the replayed
// blocks make (wiki/06-api-v0.md 6.1 and 6.2, wiki/09-reliability.md 3).

@module("envio") external defineSidecar: {..} => unknown = "defineSidecar"

let contract = defineSidecar({"functions": {"ping": {"input": {"n": S.int}}}})
// `defineSidecar` is pure: the indexer side binds the contract itself, the way
// the test harness does for a fixture.
contract->(Utils.magic: unknown => SidecarContract.t)->SidecarContract.set

type running = {internalPort: int, close: unit => promise<unknown>, waitIdle: unit => promise<unit>}
type startOptions = {
  internalPort: int,
  publicPort: int,
  indexerInternalUrl: string,
  logLevel: string,
  startJobs: bool,
}
type sidecarRuntime = {start: startOptions => promise<running>}
@module("envio/sidecar")
external createSidecar: (unknown, {..}) => sidecarRuntime = "createSidecar"

type sidecarCaller = {ping: {"n": int} => string}
type handlerContext = {sidecar: sidecarCaller}

let ping = (blockNumber, ~logIndex=0): MockSource.itemMock => {
  blockNumber,
  logIndex,
  handler: async args => {
    let context = args.context->(Utils.magic: Internal.handlerContext => handlerContext)
    let _ = context.sidecar.ping({"n": blockNumber})
  },
}

let scenario = Scenario.make(
  ~supervised=false,
  ~configYaml=`
name: sidecar-delivery
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

let callIds = (request: FakeSidecar.request) =>
  (
    request.body->(Utils.magic: JSON.t => {"calls": array<{"id": string}>})
  )["calls"]->Array.map(call => call["id"])

describe("Sidecar call delivery", () => {
  Async.it("posts a committed batch's calls to the sidecar", async t => {
    let sidecar = await FakeSidecar.start()
    let sender = SidecarSender.make(~url=sidecar.url)
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
          () => sidecar.requests->Array.length > 0,
          ~message="the calls to reach the sidecar",
        )
      },
    )
    sender->SidecarSender.stop
    await sidecar.close()

    let request = sidecar.requests->Array.getUnsafe(0)
    let body = request.body->(Utils.magic: JSON.t => {"batchId": string, "calls": JSON.t})
    t.expect((request.path, typeof(body["batchId"]), body["calls"])).toEqual((
      "/envio/calls",
      #string,
      [
        {
          "id": "1337:101:0r0:0",
          "fn": "ping",
          "chainId": 1337,
          "blockNumber": 101,
          "blockTimestamp": 101,
          "input": {"n": 101},
        },
      ]->Utils.magic,
    ))
  })

  Async.it("runs the delivered call in a real sidecar runtime", async t => {
    let ran = []
    let running = await createSidecar(
      contract,
      {
        "functions": {
          "ping": async (args: {"input": {"n": int}}) => ran->Array.push(args["input"])->ignore,
        },
      },
    ).start({
      internalPort: 0,
      publicPort: 0,
      indexerInternalUrl: "http://127.0.0.1:1",
      logLevel: "silent",
      startJobs: false,
    })
    let sender = SidecarSender.make(~url=`http://127.0.0.1:${running.internalPort->Int.toString}`)
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
          () => ran->Array.length > 0,
          ~message="the sidecar to run the call",
        )
        await running.waitIdle()
      },
    )
    sender->SidecarSender.stop
    let _ = await running.close()

    t.expect(ran).toEqual([{"n": 101}])
  })

  // T-005 Done when: delivery never blocks the write fiber.
  Async.it("keeps committing batches while the sidecar takes 10 s to answer", async t => {
    let sidecar = await FakeSidecar.start(
      ~respond=async request => {
        await Utils.delay(10_000)
        await FakeSidecar.runtimeReply(request)
      },
    )
    let sender = SidecarSender.make(~url=sidecar.url, ~callsTimeoutMs=30_000)
    let committedWithin = ref(None)
    await scenario->Scenario.run(
      ~sources,
      ~reorgThresholdReadyTolerance=0,
      ~sidecarSender=sender,
      async (~indexer, ~source) => {
        let source = source(1337)
        await Scenario.enterReorgThreshold(~t, ~indexer, ~source)
        let started = Date.now()
        source.resolveGetItemsOrThrow([ping(101)], ~latestFetchedBlockNumber=101)
        await indexer.getBatchWritePromise()
        await MockSource.waitItemsQuery(source)
        source.resolveGetItemsOrThrow([ping(102)], ~latestFetchedBlockNumber=102)
        await indexer.getBatchWritePromise()
        committedWithin := Some(Date.now() -. started)
      },
    )
    sender->SidecarSender.stop
    await sidecar.close()

    t.expect(
      committedWithin.contents->Option.map(ms => ms < 5_000.),
      ~message="both batches commit long before the sidecar answers",
    ).toEqual(Some(true))
  })

  // T-005 Done when: sidecar down, the indexer keeps indexing, drops are counted.
  Async.it("keeps indexing when the sidecar is down and counts the calls it drops", async t => {
    let url = await FakeSidecar.down()
    let sender = SidecarSender.make(~url, ~queueMax=1, ~backoffBaseMs=1, ~backoffCapMs=5)
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
        await MockSource.waitItemsQuery(source)
        source.resolveGetItemsOrThrow([ping(102)], ~latestFetchedBlockNumber=102)
        await indexer.getBatchWritePromise()
        metrics :=
          Some((
            await indexer.metric("envio_sidecar_calls_dropped_total"),
            await indexer.metric("envio_sidecar_queue_size"),
            await indexer.metric("envio_sidecar_calls_sent_total"),
          ))
      },
    )
    sender->SidecarSender.stop

    t.expect(metrics.contents).toEqual(
      Some((
        [{IndexerRunner.value: "1", labels: dict{"reason": "overflow"}}],
        [{value: "1", labels: Dict.make()}],
        [{value: "0", labels: Dict.make()}],
      )),
    )
  })

  // T-005 Done when: rollback notice sent with chainId + rollbackToBlock. It
  // has to arrive before the replayed block's calls: the sidecar forgets the
  // ids above the block on the notice, and would dedupe a replay it saw first.
  Async.it("sends the rollback notice before the replayed block's calls", async t => {
    let sidecar = await FakeSidecar.start()
    let sender = SidecarSender.make(~url=sidecar.url)
    await scenario->Scenario.run(
      ~sources,
      ~reorgThresholdReadyTolerance=0,
      ~sidecarSender=sender,
      async (~indexer, ~source) => {
        let source = source(1337)
        await Scenario.enterReorgThreshold(~t, ~indexer, ~source)
        source.resolveGetItemsOrThrow([ping(101), ping(102)], ~latestFetchedBlockNumber=102)
        await indexer.getBatchWritePromise()
        await Scenario.reorgAbove(
          ~indexer,
          ~source,
          ~head=102,
          ~validUpTo=101,
          ~refetched=[ping(102)],
        )
        await Scenario.waitUntil(
          () => sidecar.requests->Array.length >= 3,
          ~message="the replayed call to reach the sidecar",
        )
      },
    )
    sender->SidecarSender.stop
    await sidecar.close()

    t.expect(
      sidecar.requests->Array.map(
        request =>
          switch request.path {
          | "/envio/calls" => ("/envio/calls", request->callIds->Utils.magic)
          | path => (path, request.body)
          },
      ),
    ).toEqual([
      ("/envio/calls", ["1337:101:0r0:0", "1337:102:0r0:0"]->Utils.magic),
      ("/envio/rollback", {"chainId": 1337, "rollbackToBlock": 101}->Utils.magic),
      ("/envio/calls", ["1337:102:0r0:0"]->Utils.magic),
    ])
  })
})
