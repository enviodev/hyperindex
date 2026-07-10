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

// Guarantees the temp server is closed even if the body throws, so a failing
// assertion can't leak a listener and hang/cross-talk with later tests.
let withServer = async (handler, body) => {
  let (server, endpointUrl) = await startServer(handler)
  try {
    let result = await body(endpointUrl)
    server->close
    result
  } catch {
  | exn =>
    server->close
    throw(exn)
  }
}

describe("HyperFuelSource - getHeightOrThrow", () => {
  let chain = ChainMap.Chain.makeUnsafe(~chainId=0)

  // The native client validates that the token is a UUID before sending requests.
  let apiToken = "11111111-1111-1111-1111-111111111111"

  Async.it("Requests height via the client with auth and user agent headers", async t => {
    let capturedHeaders = ref(None)
    await withServer((req, res) => {
      capturedHeaders := Some(req.headers)
      res->writeHead(200)
      res->endWith(`{"height": 123}`)
    }, async endpointUrl => {
      let source = HyperFuelSource.make({
        chain,
        endpointUrl,
        apiToken: Some(apiToken),
      })
      let {height} = await source.getHeightOrThrow()

      let headers = capturedHeaders.contents->Option.getOrThrow
      t.expect((
        height,
        headers->Dict.get("authorization"),
        headers->Dict.get("user-agent"),
      )).toEqual((
        123,
        Some(`Bearer ${apiToken}`),
        Some(`hyperindex/${Utils.EnvioPackage.value.version}`),
      ))
    })
  })

  Async.it("Blocks forever on 401 instead of throwing for a retry", async t => {
    await withServer((_req, res) => {
      res->writeHead(401)
      res->endWith("Unauthorized")
    }, async endpointUrl => {
      let source = HyperFuelSource.make({
        chain,
        endpointUrl,
        apiToken: Some(apiToken),
      })
      let result = await Promise.race([
        source.getHeightOrThrow()->Promise.thenResolve(_ => "resolved"),
        Time.resolvePromiseAfterDelay(~delayMilliseconds=300)->Promise.thenResolve(() => "blocked"),
      ])

      t.expect(result).toEqual("blocked")
    })
  })
})
