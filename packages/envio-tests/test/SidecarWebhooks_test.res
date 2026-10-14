open Vitest

// Webhooks the sidecar posts come back into the indexer and run their
// `indexer.onWebhook` handler in the next batch of their chain, with a normal
// handler context (wiki/06-api-v0.md 4 and 6.3, T-006).

@module("envio") external defineSidecar: {..} => unknown = "defineSidecar"

let contract = defineSidecar({
  "functions": {"ping": {"input": {"n": S.int}}},
  "webhooks": {"swapPriced": {"body": {"swapId": S.string, "usd": S.int}}},
})
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

type swapPriced = {swapId: string, usd: int}
type emit = {swapPriced: swapPriced => promise<unknown>}
type pingArgs = {input: {"n": int}, emit: emit}

type response
@val external fetch: (string, {..}) => promise<response> = "fetch"
@get external status: response => int = "status"

let post = async (url, ~name, ~body: JSON.t) =>
  (
    await fetch(
      `${url}/webhooks/${name}`,
      {
        "method": "POST",
        "headers": {"content-type": "application/json"},
        "body": body->JSON.stringify,
      },
    )
  )->status

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
name: sidecar-webhooks
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
  ~schema=`
type Priced {
  id: ID!
  usd: Int!
  block: Int!
}
type CallSeen {
  id: ID!
  kind: String!
  fn: String!
  n: Int!
  reason: String
}
`,
  ~handlers=`
import { indexer } from "envio";

indexer.onWebhook({ name: "swapPriced" }, async ({ webhook, context }) => {
  const body = webhook.body as { swapId: string; usd: number };
  context.Priced.set({ id: body.swapId, usd: body.usd, block: webhook.block.number });
});

indexer.onWebhook({ name: "sidecar.ack" }, async ({ webhook, context }) => {
  const { callId, fn, input } = webhook.body as { callId: string; fn: string; input: { n: number } };
  context.CallSeen.set({ id: callId, kind: "ack", fn, n: input.n, reason: undefined });
});

indexer.onWebhook({ name: "sidecar.dropped" }, async ({ webhook, context }) => {
  const { callId, fn, input, reason } = webhook.body as {
    callId: string;
    fn: string;
    input: { n: number };
    reason: string;
  };
  context.CallSeen.set({ id: callId, kind: "dropped", fn, n: input.n, reason });
});
`,
)

let methods: array<MockSource.method> = [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes]
let sources: array<Scenario.sourceMock> = [{chain: 1337, methods}]

type priced = {id: string, usd: int, block: int}
type callSeen = {id: string, kind: string, fn: string, n: int, reason: option<string>}

let freePort = () =>
  Promise.make((resolve, _) => {
    let server = MockRpcServer.createServer((_, _) => ())
    server->MockRpcServer.listenOnHost(0, "127.0.0.1", () => {
      let port = (server->MockRpcServer.address).port
      server->MockRpcServer.close(() => resolve(port))
    })
  })

// For writes that come back from the sidecar on their own schedule.
let rowsOnceWritten = async (indexer: IndexerRunner.t, entityName) => {
  let deadline = Date.now() +. 10_000.
  let rec poll = async () => {
    await indexer.waitUntilIdle()
    switch await indexer.query(entityName) {
    | [] if Date.now() < deadline =>
      await Utils.delay(10)
      await poll()
    | rows => rows
    }
  }
  await poll()
}

let checkpointsAt = async (indexer: IndexerRunner.t, ~blockNumber) =>
  (await indexer.queryCheckpoints())->Array.filter(checkpoint =>
    checkpoint.blockNumber === blockNumber
  )

let readyAt = async (indexer: IndexerRunner.t) => {
  let {sql, pgSchema} = indexer.pg
  let rows: array<{
    "ready_at": Null.t<Date.t>,
  }> = await sql->Sql.queryForTests(`SELECT "ready_at" FROM "${pgSchema}"."envio_chains";`)
  rows->Array.map(row => row["ready_at"]->Null.toOption->Option.isSome)
}

describe("Sidecar webhooks into the indexer", () => {
  // Found in T-010: a sidecar job's first webhook arrived while HyperSync had
  // not answered the chain's height yet. The batch made for it alone read
  // progress -1 against a head of 0 as "at the head", so the chain logged
  // "Finished backfill" and committed ready_at before indexing anything.
  Async.it(
    "does not mark a chain ready for a webhook that lands before its height is known",
    async t => {
      let answer = ref(None)
      let rows = ref([])
      let ready = ref([])
      await scenario->Scenario.run(
        ~sources,
        ~reorgThresholdReadyTolerance=0,
        ~webhookPort=0,
        async (~indexer, ~source) => {
          let _ = source(1337)
          answer :=
            Some(
              await post(
                indexer.webhookUrl(),
                ~name="swapPriced",
                ~body={"swapId": "s1", "usd": 42}->Utils.magic,
              ),
            )
          rows := (await rowsOnceWritten(indexer, "Priced"))
          ready := (await readyAt(indexer))
        },
      )

      t.expect((answer.contents, rows.contents, ready.contents)).toEqual((
        Some(202),
        [{id: "s1", usd: 42, block: 0}],
        [false],
      ))
    },
  )

  // T-006 Done when: result handler writes are visible (in Postgres, so in
  // GraphQL). The chain is idle at the head: the webhook gets a batch alone.
  Async.it("applies a posted webhook on an idle chain at its head block", async t => {
    let answer = ref(None)
    let rows = ref([])
    await scenario->Scenario.run(
      ~sources,
      ~reorgThresholdReadyTolerance=0,
      ~webhookPort=0,
      async (~indexer, ~source) => {
        let source = source(1337)
        await Scenario.enterReorgThreshold(~t, ~indexer, ~source)
        source.resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=101)
        await indexer.getBatchWritePromise()
        answer :=
          Some(
            await post(
              indexer.webhookUrl(),
              ~name="swapPriced",
              ~body={"swapId": "s1", "usd": 42}->Utils.magic,
            ),
          )
        await indexer.getBatchWritePromise()
        rows := (await indexer.query("Priced"))
      },
    )

    t.expect((answer.contents, rows.contents)).toEqual((
      Some(202),
      [{id: "s1", usd: 42, block: 101}],
    ))
  })

  // T-006 Done when: results arriving while a batch is running wait for the
  // next one, on a checkpoint of their own.
  Async.it("runs a webhook posted during a batch in the next batch", async t => {
    let release = ref(() => ())
    let blocked = Promise.make((resolve, _) => release := resolve)
    let started = ref(false)
    let checkpoints = ref([])
    await scenario->Scenario.run(
      ~sources,
      ~reorgThresholdReadyTolerance=0,
      ~webhookPort=0,
      async (~indexer, ~source) => {
        let source = source(1337)
        await Scenario.enterReorgThreshold(~t, ~indexer, ~source)
        source.resolveGetItemsOrThrow(
          [
            {
              blockNumber: 101,
              logIndex: 0,
              handler: async _ => {
                started := true
                await blocked
              },
            },
          ],
          ~latestFetchedBlockNumber=101,
        )
        await Scenario.waitUntil(() => started.contents, ~message="the batch to start")
        let status = await post(
          indexer.webhookUrl(),
          ~name="swapPriced",
          ~body={"swapId": "s1", "usd": 42}->Utils.magic,
        )
        release.contents()
        await indexer.getBatchWritePromise()
        await indexer.waitUntilIdle()
        checkpoints :=
          (await checkpointsAt(indexer, ~blockNumber=101))->Array.map(
            checkpoint => (status, checkpoint.eventsProcessed),
          )
      },
    )

    t.expect(checkpoints.contents).toEqual([(202, 1), (202, 0)])
  })

  Async.it("applies a webhook a real sidecar emits from a called function", async t => {
    let port = await freePort()
    let running = await createSidecar(
      contract,
      {
        "functions": {
          "ping": async (args: pingArgs) => {
            let _ = await args.emit.swapPriced({
              swapId: `s${args.input["n"]->Int.toString}`,
              usd: 7,
            })
          },
        },
      },
    ).start({
      internalPort: 0,
      publicPort: 0,
      indexerInternalUrl: `http://127.0.0.1:${port->Int.toString}`,
      logLevel: "silent",
      startJobs: false,
    })
    let sender = SidecarSender.make(~url=`http://127.0.0.1:${running.internalPort->Int.toString}`)
    let rows = ref([])
    await scenario->Scenario.run(
      ~sources,
      ~reorgThresholdReadyTolerance=0,
      ~sidecarSender=sender,
      ~webhookPort=port,
      async (~indexer, ~source) => {
        let source = source(1337)
        await Scenario.enterReorgThreshold(~t, ~indexer, ~source)
        source.resolveGetItemsOrThrow([ping(101)], ~latestFetchedBlockNumber=101)
        await indexer.getBatchWritePromise()
        rows := (await indexer->rowsOnceWritten("Priced"))
      },
    )
    sender->SidecarSender.stop
    let _ = await running.close()

    t.expect(rows.contents).toEqual([{id: "s101", usd: 7, block: 101}])
  })

  Async.it(
    "runs sidecar.ack for an accepted call and sidecar.dropped for a dropped one",
    async t => {
      let sidecar = await FakeSidecar.start()
      let acked = ref([])
      await scenario->Scenario.run(
        ~sources,
        ~reorgThresholdReadyTolerance=0,
        ~sidecarSender=SidecarSender.make(~url=sidecar.url),
        async (~indexer, ~source) => {
          let source = source(1337)
          await Scenario.enterReorgThreshold(~t, ~indexer, ~source)
          source.resolveGetItemsOrThrow([ping(101)], ~latestFetchedBlockNumber=101)
          await indexer.getBatchWritePromise()
          await Scenario.waitUntil(
            () => sidecar.requests->Array.length > 0,
            ~message="the call to reach the sidecar",
          )
          acked := (await indexer->rowsOnceWritten("CallSeen"))
        },
      )
      await sidecar.close()

      let url = await FakeSidecar.down()
      let dropped = ref([])
      await scenario->Scenario.run(
        ~sources,
        ~reorgThresholdReadyTolerance=0,
        ~sidecarSender=SidecarSender.make(~url, ~queueMax=1, ~backoffBaseMs=1, ~backoffCapMs=5),
        async (~indexer, ~source) => {
          let source = source(1337)
          await Scenario.enterReorgThreshold(~t, ~indexer, ~source)
          source.resolveGetItemsOrThrow([ping(101)], ~latestFetchedBlockNumber=101)
          await indexer.getBatchWritePromise()
          await MockSource.waitItemsQuery(source)
          source.resolveGetItemsOrThrow([ping(102)], ~latestFetchedBlockNumber=102)
          await indexer.getBatchWritePromise()
          dropped := (await indexer->rowsOnceWritten("CallSeen"))
        },
      )

      t.expect((acked.contents, dropped.contents)).toEqual((
        [{id: "1337:101:0r0:0", kind: "ack", fn: "ping", n: 101, reason: None}],
        [
          {
            id: "1337:101:0r0:0",
            kind: "dropped",
            fn: "ping",
            n: 101,
            reason: Some("the queue is over its bound of 1 calls (ENVIO_SIDECAR_QUEUE_MAX)"),
          },
        ],
      ))
    },
  )

  // v0: a webhook whose block is reorged away is undone with it, not replayed.
  Async.it("undoes a webhook's writes when its block is rolled back", async t => {
    let before = ref([])
    let after = ref([])
    await scenario->Scenario.run(
      ~sources,
      ~reorgThresholdReadyTolerance=0,
      ~webhookPort=0,
      async (~indexer, ~source) => {
        let source = source(1337)
        await Scenario.enterReorgThreshold(~t, ~indexer, ~source)
        source.resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=102)
        await indexer.getBatchWritePromise()
        let _ = await post(
          indexer.webhookUrl(),
          ~name="swapPriced",
          ~body={"swapId": "s1", "usd": 42}->Utils.magic,
        )
        await indexer.getBatchWritePromise()
        before := (await indexer.query("Priced"))
        await Scenario.reorgAbove(~indexer, ~source, ~head=102, ~validUpTo=101)
        after := (await indexer.query("Priced"))
      },
    )

    t.expect((before.contents, after.contents)).toEqual(([{id: "s1", usd: 42, block: 102}], []))
  })
})
