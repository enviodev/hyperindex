// The loopback listener the sidecar's `emit` posts webhooks to
// (wiki/06-api-v0.md 6.3). Its own server, never the public one: anything that
// can reach it can write through the indexer. It only checks and forwards;
// queueing on a chain and finding the handler belong to whoever owns the chain.

// What the listener answered, for the indexer's `/metrics`
// (wiki/implementation/ui-design.md 4: rejected webhooks make a sidecar Degraded).
type stats = {
  // Accepted onto a chain's queue, by webhook. A resent idempotency key that is
  // answered from memory is not counted again.
  received: dict<int>,
  // Refused for good (4xx), by webhook, then reason: `unauthorized`,
  // `reserved`, `chain`, `schema`. The 503 while the indexer starts is not
  // counted: `emit` retries it.
  rejected: dict<dict<int>>,
}

type t = {url: string, close: unit => promise<unit>, stats: stats}

// The listener this process runs, if any: the one the server's `/metrics`
// reports on. Only `startForRun` sets it.
let current: ref<option<stats>> = ref(None)

let makeStats = () => {received: Dict.make(), rejected: Dict.make()}

let increment = (counts: dict<int>, key) =>
  counts->Dict.set(key, counts->Dict.get(key)->Option.getOr(0) + 1)

let countRejected = (stats, ~name, ~reason) => {
  let byReason = switch stats.rejected->Utils.Dict.dangerouslyGetNonOption(name) {
  | Some(byReason) => byReason
  | None =>
    let byReason = Dict.make()
    stats.rejected->Dict.set(name, byReason)
    byReason
  }
  byReason->increment(reason)
}

let sortedByKey = entries => entries->Array.toSorted(((a, _), (b, _)) => String.compare(a, b))

// `envio_webhooks_received_total` and `envio_webhooks_rejected_total`, as
// exposition text. Every webhook in the contract has a received series from
// the start, so a rate over it never begins with a missing series.
let renderMetrics = (stats, ~contract: option<SidecarContract.t>) => {
  let received = stats.received->Dict.copy
  contract
  ->Option.flatMap(contract => contract.webhooks)
  ->Option.forEach(webhooks =>
    webhooks
    ->Dict.keysToArray
    ->Array.forEach(name =>
      if received->Dict.get(name)->Option.isNone {
        received->Dict.set(name, 0)
      }
    )
  )
  let b: Metrics.builder = {out: ""}
  b->Metrics.series(
    ~name="envio_webhooks_received_total",
    ~help="Webhooks from the sidecar the indexer accepted onto a chain's queue, by webhook. A resent idempotency key is not counted again.",
    ~kind="counter",
    ~entries=received
    ->Dict.toArray
    ->sortedByKey
    ->Array.map(((name, count)) => (`{webhook="${name->Metrics.escapeLabelValue}"}`, count)),
    ~value=Int.toFloat,
  )
  b->Metrics.series(
    ~name="envio_webhooks_rejected_total",
    ~help="Webhooks the indexer refused for good, by webhook and reason (unauthorized, reserved, chain, schema). The 503 while it starts is retried by the sidecar and not counted.",
    ~kind="counter",
    ~entries=stats.rejected
    ->Dict.toArray
    ->sortedByKey
    ->Array.flatMap(((name, byReason)) =>
      byReason
      ->Dict.toArray
      ->sortedByKey
      ->Array.map(((reason, count)) => (
        `{webhook="${name->Metrics.escapeLabelValue}",reason="${reason}"}`,
        count,
      ))
    ),
    ~value=Int.toFloat,
  )
  b.out
}

// A key resent after this many newer webhooks is applied again.
let idempotencyBound = 100_000

let pid: int = %raw(`process.pid`)

type urlParts = {hostname: string, port: string}
@new external parseUrl: string => urlParts = "URL"

let hostAndPort = (url: string) => {
  let {hostname, port} = parseUrl(url)
  (
    // `URL` keeps the brackets of an IPv6 host, which `listen` doesn't take.
    hostname->String.replaceRegExp(/^\[|\]$/g, ""),
    port === "" ? 80 : port->Int.fromString->Option.getOr(80),
  )
}

type accepted = {id: string, chainId: ChainId.t}

let promiseListening = (app, ~host, ~port, ~stats): promise<t> =>
  Promise.make((resolve, reject) => {
    let server = ref(None)
    let listening = app->Express.listenOn(port, host, () =>
      server.contents->Option.forEach(
        server => {
          let boundPort = (server->Express.address)["port"]
          resolve({
            url: `http://${host}:${boundPort->Int.toString}`,
            stats,
            close: () =>
              Promise.make(
                (resolve, _) => {
                  server->Express.closeAllConnections
                  server->Express.close(() => resolve())
                },
              ),
          })
        },
      )
    )
    server := Some(listening)
    listening->Express.onError(error => reject(error->JsExn.anyToExnInternal))
  })

let start = (
  ~host,
  ~port,
  ~chainIds: array<ChainId.t>,
  ~secret: option<string>,
  ~contract: unit => option<SidecarContract.t>,
  ~isReady: ChainId.t => bool,
  ~deliver: Internal.webhookDelivery => unit,
): promise<t> => {
  let seen: Map.t<string, accepted> = Map.make()
  let counter = ref(0)
  let stats = makeStats()

  let resolveChain = (header: option<string>) =>
    switch (header, chainIds) {
    | (None, [only]) => Ok(only)
    | (None, _) => Error("x-envio-chain-id is required: the indexer indexes several chains")
    | (Some(raw), _) =>
      switch raw->Int.fromString {
      | Some(id) if chainIds->Array.some(chainId => chainId->ChainId.toInt === id) =>
        Ok(ChainId.fromInt(id))
      | _ => Error(`x-envio-chain-id ${raw} is not a chain this indexer indexes`)
      }
    }

  let checkBody = (~name, body: JSON.t) =>
    switch contract()->Option.flatMap(contract =>
      contract->SidecarContract.webhookBodySchema(~name)
    ) {
    | None => Ok()
    | Some({body: schema}) =>
      try {
        let _ = body->S.parseJsonOrThrow(schema)
        Ok()
      } catch {
      | S.Raised(error) => Error(error->S.Error.message)
      }
    }

  let remember = (key, accepted) => {
    seen->Map.set(key, accepted)
    if seen->Map.size > idempotencyBound {
      switch seen->Map.keys->Iterator.next {
      | {value: Some(oldest)} => seen->Map.delete(oldest)->ignore
      | _ => ()
      }
    }
  }

  let app = Express.make()
  app->Express.useFor("/webhooks", Express.jsonMiddlewareWith({"limit": "1mb"}))
  app->Express.post("/webhooks/:name", (req, res) => {
    let headers = req.headers
    let name = req->Express.params->Dict.getUnsafe("name")
    let refuse = (status, error, detail) => {
      if status < 500 {
        stats->countRejected(~name, ~reason=error)
      }
      res
      ->Express.status(status)
      ->Express.json({"error": error, "detail": detail}->(Utils.magic: {..} => JSON.t))
    }
    if secret->Option.isSome && headers->Dict.get("x-envio-webhook-secret") !== secret {
      refuse(401, "unauthorized", "x-envio-webhook-secret doesn't match ENVIO_WEBHOOK_SECRET")
    } else if name->String.startsWith("sidecar.") {
      refuse(400, "reserved", `'${name}' is reserved for the indexer's own webhooks`)
    } else {
      switch resolveChain(headers->Dict.get("x-envio-chain-id")) {
      | Error(detail) => refuse(400, "chain", detail)
      | Ok(chainId) if !isReady(chainId) =>
        res->Express.set("retry-after", "1")
        refuse(503, "not_ready", "the indexer is starting")
      | Ok(chainId) =>
        let idempotencyKey = headers->Dict.get("idempotency-key")
        switch idempotencyKey->Option.flatMap(key => seen->Map.get(key)) {
        | Some(accepted) =>
          res->Express.status(200)->Express.json(accepted->(Utils.magic: accepted => JSON.t))
        | None =>
          let body = req->Express.body
          switch checkBody(~name, body) {
          | Error(detail) => refuse(400, "schema", detail)
          | Ok() =>
            counter := counter.contents + 1
            let accepted = {
              id: `wh_${pid->Int.toString}_${counter.contents->Int.toString}`,
              chainId,
            }
            deliver({
              id: accepted.id,
              chainId,
              name,
              body,
              ?idempotencyKey,
              receivedAt: Date.now(),
            })
            idempotencyKey->Option.forEach(key => remember(key, accepted))
            stats.received->increment(name)
            res->Express.status(202)->Express.json(accepted->(Utils.magic: accepted => JSON.t))
          }
        }
      }
    }
  })

  promiseListening(app, ~host, ~port, ~stats)
}

// Where `ENVIO_INDEXER_INTERNAL_URL` says, for an indexer with `sidecar:`
// configured. A port that is taken costs the webhooks, not the indexing.
let startForRun = async (~config: Config.t, ~isReady, ~deliver) => {
  let (host, port) = Env.Sidecar.indexerInternalUrl->hostAndPort
  switch await start(
    ~host,
    ~port,
    ~chainIds=config.chainMap->ChainMap.values->Array.map(chain => chain.id),
    ~secret=Env.Sidecar.webhookSecret,
    ~contract=SidecarContract.get,
    ~isReady,
    ~deliver,
  ) {
  | listener =>
    current := Some(listener.stats)
    Logging.info({"msg": "Listening for sidecar webhooks", "url": listener.url})
    Some(listener)
  | exception exn =>
    Logging.errorWithExn(
      exn->Utils.prettifyExn,
      `Failed to listen for sidecar webhooks at ${Env.Sidecar.indexerInternalUrl} (ENVIO_INDEXER_INTERNAL_URL). Indexing goes on; the sidecar's webhooks won't arrive.`,
    )
    None
  }
}
