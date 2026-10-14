// The loopback listener the sidecar's `emit` posts webhooks to
// (wiki/06-api-v0.md 6.3). Its own server, never the public one: anything that
// can reach it can write through the indexer. It only checks and forwards;
// queueing on a chain and finding the handler belong to whoever owns the chain.

type t = {url: string, close: unit => promise<unit>}

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
    let refuse = (status, error, detail) =>
      res
      ->Express.status(status)
      ->Express.json({"error": error, "detail": detail}->(Utils.magic: {..} => JSON.t))
    let name = req->Express.params->Dict.getUnsafe("name")
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
            res->Express.status(202)->Express.json(accepted->(Utils.magic: accepted => JSON.t))
          }
        }
      }
    }
  })

  Promise.make((resolve, reject) => {
    let server = ref(None)
    let listening = app->Express.listenOn(port, host, () =>
      server.contents->Option.forEach(
        server => {
          let boundPort = (server->Express.address)["port"]
          resolve({
            url: `http://${host}:${boundPort->Int.toString}`,
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
}
