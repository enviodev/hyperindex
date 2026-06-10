open Vitest

// For Logging.setLogger call
let _ = Env.logStrategy

type server
type req = {headers: dict<string>}
type res

@module("node:http")
external createServer: ((req, res) => unit) => server = "createServer"
@send external listen: (server, int, unit => unit) => unit = "listen"
@send external close: server => unit = "close"
@send external address: server => {"port": int} = "address"
@send external writeHead: (res, int) => unit = "writeHead"
@send external endWith: (res, string) => unit = "end"

let startServer = async handler => {
  let server = createServer(handler)
  await Promise.make((resolve, _) => server->listen(0, () => resolve()))
  let port = (server->address)["port"]
  (server, `http://127.0.0.1:${port->Int.toString}`)
}

describe("HyperFuelSource - getHeightOrThrow", () => {
  let chain = ChainMap.Chain.makeUnsafe(~chainId=0)

  Async.it("Requests height via the client with auth and user agent headers", async t => {
    let capturedHeaders = ref(None)
    let (server, endpointUrl) = await startServer((req, res) => {
      capturedHeaders := Some(req.headers)
      res->writeHead(200)
      res->endWith(`{"height": 123}`)
    })

    let source = HyperFuelSource.make({
      chain,
      endpointUrl,
      apiToken: Some("test-token"),
    })
    let height = await source.getHeightOrThrow()
    server->close

    let headers = capturedHeaders.contents->Option.getOrThrow
    t.expect((
      height,
      headers->Dict.get("authorization"),
      headers->Dict.get("user-agent"),
    )).toEqual((
      123,
      Some("Bearer test-token"),
      Some(`hyperindex/${Utils.EnvioPackage.value.version}`),
    ))
  })

  Async.it("Blocks forever on 401 instead of throwing for a retry", async t => {
    let (server, endpointUrl) = await startServer((_req, res) => {
      res->writeHead(401)
      res->endWith("Unauthorized")
    })

    let source = HyperFuelSource.make({
      chain,
      endpointUrl,
      apiToken: Some("rejected-token"),
    })
    let result = await Promise.race([
      source.getHeightOrThrow()->Promise.thenResolve(_ => "resolved"),
      Time.resolvePromiseAfterDelay(~delayMilliseconds=300)->Promise.thenResolve(() => "blocked"),
    ])
    server->close

    t.expect(result).toEqual("blocked")
  })
})
