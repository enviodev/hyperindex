open Vitest

// The loopback listener the sidecar's `emit` posts to (wiki/06-api-v0.md 6.3):
// every answer it gives before a webhook reaches a chain's queue.

@module("envio") external defineSidecar: {..} => unknown = "defineSidecar"

let contract = defineSidecar({
  "functions": {"ping": {"input": {"n": S.int}}},
  "webhooks": {"swapPriced": {"body": {"swapId": S.string, "usd": S.int}}},
})->(Utils.magic: unknown => SidecarContract.t)

type headers
type response
@val external fetch: (string, {..}) => promise<response> = "fetch"
@get external status: response => int = "status"
@get external responseHeaders: response => headers = "headers"
@send external header: (headers, string) => Nullable.t<string> = "get"
@send external json: response => promise<JSON.t> = "json"

let post = async (url, ~name, ~body: JSON.t, ~headers=dict{}) => {
  let headers = headers->Dict.copy
  headers->Dict.set("content-type", "application/json")
  let response = await fetch(
    `${url}/webhooks/${name}`,
    {"method": "POST", "headers": headers, "body": body->JSON.stringify},
  )
  (response->status, await response->json)
}

let priced: JSON.t = {"swapId": "s1", "usd": 42}->Utils.magic

let start = (~chainIds=[ChainId.fromInt(1)], ~secret=?, ~isReady=_ => true) => {
  let delivered = []
  WebhookListener.start(
    ~host="127.0.0.1",
    ~port=0,
    ~chainIds,
    ~secret,
    ~contract=() => Some(contract),
    ~isReady,
    ~deliver=delivery => delivered->Array.push(delivery)->ignore,
  )->Promise.thenResolve(listener => (listener, delivered))
}

let shape = ((status, body): (int, JSON.t)) => {
  let body = body->(Utils.magic: JSON.t => {"id": unknown, "chainId": unknown})
  (status, typeof(body["id"]), body["chainId"])
}

describe("Webhook listener", () => {
  Async.it("queues a webhook on the only chain and answers 202 with its id", async t => {
    let (listener, delivered) = await start()
    let answer = await post(listener.url, ~name="swapPriced", ~body=priced)
    await listener.close()

    t.expect((
      answer->shape,
      delivered->Array.map(d => (d.chainId, d.name, d.body, d.idempotencyKey)),
    )).toEqual(((202, #string, 1->Utils.magic), [(ChainId.fromInt(1), "swapPriced", priced, None)]))
  })

  Async.it("answers a repeated idempotency key with the first id and queues it once", async t => {
    let (listener, delivered) = await start()
    let headers = dict{"idempotency-key": "1:5:3r0:0#0"}
    let (_, first) = await post(listener.url, ~name="swapPriced", ~body=priced, ~headers)
    let (status, second) = await post(listener.url, ~name="swapPriced", ~body=priced, ~headers)
    await listener.close()

    t.expect((status, second == first, delivered->Array.length)).toEqual((200, true, 1))
  })

  Async.it("refuses what a retry cannot fix with 4xx, and asks to retry with 503", async t => {
    let ready = ref(false)
    let (listener, delivered) = await start(
      ~chainIds=[ChainId.fromInt(1), ChainId.fromInt(2)],
      ~secret="s3cret",
      ~isReady=_ => ready.contents,
    )
    let secret = dict{"x-envio-webhook-secret": "s3cret", "x-envio-chain-id": "1"}
    let notReady = await fetch(
      `${listener.url}/webhooks/swapPriced`,
      {
        "method": "POST",
        "headers": secret->Dict.copy->Utils.magic,
        "body": priced->JSON.stringify,
      },
    )
    let notReady = (notReady->status, notReady->responseHeaders->header("retry-after"))
    ready := true
    let statuses =
      [
        await post(
          listener.url,
          ~name="swapPriced",
          ~body=priced,
          ~headers=dict{"x-envio-chain-id": "1"},
        ),
        await post(
          listener.url,
          ~name="swapPriced",
          ~body=priced,
          ~headers=dict{"x-envio-webhook-secret": "wrong", "x-envio-chain-id": "1"},
        ),
        await post(listener.url, ~name="sidecar.ack", ~body=priced, ~headers=secret),
        await post(
          listener.url,
          ~name="swapPriced",
          ~body=priced,
          ~headers=dict{"x-envio-webhook-secret": "s3cret"},
        ),
        await post(
          listener.url,
          ~name="swapPriced",
          ~body=priced,
          ~headers=dict{"x-envio-webhook-secret": "s3cret", "x-envio-chain-id": "7"},
        ),
        await post(
          listener.url,
          ~name="swapPriced",
          ~body={"swapId": "s1", "usd": "lots"}->Utils.magic,
          ~headers=secret,
        ),
      ]->Array.map(
        ((status, body)) => (status, (body->(Utils.magic: JSON.t => {"error": string}))["error"]),
      )
    await listener.close()

    t.expect((notReady, statuses, delivered->Array.length)).toEqual((
      (503, Nullable.Value("1")),
      [
        (401, "unauthorized"),
        (401, "unauthorized"),
        (400, "reserved"),
        (400, "chain"),
        (400, "chain"),
        (400, "schema"),
      ],
      0,
    ))
  })

  Async.it("queues a webhook the contract doesn't declare with its JSON body as is", async t => {
    let (listener, delivered) = await start()
    let body: JSON.t = {"anything": [1, 2]}->Utils.magic
    let (status, _) = await post(listener.url, ~name="custom", ~body)
    await listener.close()

    t.expect((status, delivered->Array.map(d => (d.name, d.body)))).toEqual((
      202,
      [("custom", body)],
    ))
  })
})

describe("Webhook metrics", () => {
  Async.it("counts accepted webhooks by name and refusals by name and reason", async t => {
    let ready = ref(false)
    let (listener, _) = await start(
      ~chainIds=[ChainId.fromInt(1), ChainId.fromInt(2)],
      ~secret="s3cret",
      ~isReady=_ => ready.contents,
    )
    let secret = dict{"x-envio-webhook-secret": "s3cret", "x-envio-chain-id": "1"}
    // Not ready: retried by `emit`, so not a rejection.
    let _ = await post(listener.url, ~name="swapPriced", ~body=priced, ~headers=secret)
    ready := true
    let _ = await post(listener.url, ~name="swapPriced", ~body=priced, ~headers=secret)
    let _ = await post(
      listener.url,
      ~name="swapPriced",
      ~body=priced,
      ~headers=dict{
        "x-envio-webhook-secret": "s3cret",
        "x-envio-chain-id": "1",
        "idempotency-key": "k",
      },
    )
    // The same key again is answered from memory, not received twice.
    let _ = await post(
      listener.url,
      ~name="swapPriced",
      ~body=priced,
      ~headers=dict{
        "x-envio-webhook-secret": "s3cret",
        "x-envio-chain-id": "1",
        "idempotency-key": "k",
      },
    )
    let _ = await post(listener.url, ~name="custom", ~body=priced, ~headers=secret)
    let _ = await post(
      listener.url,
      ~name="swapPriced",
      ~body={"swapId": "s1", "usd": "lots"}->Utils.magic,
      ~headers=secret,
    )
    let _ = await post(
      listener.url,
      ~name="swapPriced",
      ~body=priced,
      ~headers=dict{"x-envio-webhook-secret": "wrong", "x-envio-chain-id": "1"},
    )
    let _ = await post(listener.url, ~name="sidecar.ack", ~body=priced, ~headers=secret)
    let _ = await post(
      listener.url,
      ~name="swapPriced",
      ~body=priced,
      ~headers=dict{"x-envio-webhook-secret": "s3cret", "x-envio-chain-id": "7"},
    )
    await listener.close()

    t.expect(
      listener.stats->WebhookListener.renderMetrics(~contract=Some(contract)),
    ).toBe(`# HELP envio_webhooks_received_total Webhooks from the sidecar the indexer accepted onto a chain's queue, by webhook. A resent idempotency key is not counted again.
# TYPE envio_webhooks_received_total counter
envio_webhooks_received_total{webhook="custom"} 1
envio_webhooks_received_total{webhook="swapPriced"} 2

# HELP envio_webhooks_rejected_total Webhooks the indexer refused for good, by webhook and reason (unauthorized, reserved, chain, schema). The 503 while it starts is retried by the sidecar and not counted.
# TYPE envio_webhooks_rejected_total counter
envio_webhooks_rejected_total{webhook="sidecar.ack",reason="reserved"} 1
envio_webhooks_rejected_total{webhook="swapPriced",reason="chain"} 1
envio_webhooks_rejected_total{webhook="swapPriced",reason="schema"} 1
envio_webhooks_rejected_total{webhook="swapPriced",reason="unauthorized"} 1`)
  })

  Async.it("starts every contract webhook at zero and goes on the indexer's /metrics", async t => {
    let (listener, _) = await start()
    let metrics = Some(TestChainMetrics.emptySnapshot)
    let body = await Server.collectMetrics(
      ~metrics,
      ~webhooks=Some(listener.stats),
      ~contract=Some(contract),
    )
    let without = await Server.collectMetrics(~metrics, ~webhooks=None)
    await listener.close()

    t.expect((body, without)).toEqual((
      Metrics.collect(~metrics) ++ `
# HELP envio_webhooks_received_total Webhooks from the sidecar the indexer accepted onto a chain's queue, by webhook. A resent idempotency key is not counted again.
# TYPE envio_webhooks_received_total counter
envio_webhooks_received_total{webhook="swapPriced"} 0

# HELP envio_webhooks_rejected_total Webhooks the indexer refused for good, by webhook and reason (unauthorized, reserved, chain, schema). The 503 while it starts is retried by the sidecar and not counted.
# TYPE envio_webhooks_rejected_total counter
`,
      Metrics.collect(~metrics),
    ))
  })
})
