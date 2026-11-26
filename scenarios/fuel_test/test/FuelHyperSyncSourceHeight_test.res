open Vitest

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

describe("Fuel HyperSync source - getHeight", () => {
  // The native client validates that the token is a UUID before sending requests.
  let apiToken = "11111111-1111-1111-1111-111111111111"

  // Height queries carry no selection, so a buffer with no registrations is all
  // the client needs.
  let chainBuffer = ChainBuffer.makeForChain(
    ~ecosystem=Ecosystem.Fuel,
    ~onEventRegistrations=[],
    ~onBlockRegistrations=[],
    ~shouldChecksum=false,
    ~addressStore=AddressStore.make(~ecosystem=Ecosystem.Fuel, ~contracts=[]),
  )

  let makeSource = (~url, ~apiToken): Source.t =>
    NativeSource.makeChainSources(
      {
        chainId: 0,
        ecosystem: Fuel,
        hyperSync: {
          url,
          apiToken,
          httpReqTimeoutMillis: 10_000,
          serializationFormat: Json,
          enableQueryCaching: false,
          logFilter: "error",
        },
        rpcs: [],
        maxAddressesPerRequest: 5_000,
        userAgent: NativeSource.userAgent,
      },
      ~chainId=0->ChainId.fromInt,
      ~chainBuffer,
      ~logger=Logger.makeInMemory(),
    )->Array.getUnsafe(0)

  Async.it("Requests height via the client with auth and user agent headers", async t => {
    let capturedHeaders = ref(None)
    await withServer(
      (req, res) => {
        capturedHeaders := Some(req.headers)
        res->writeHead(200)
        res->endWith(`{"height": 123}`)
      },
      async url => {
        let {result} = await makeSource(~url, ~apiToken=Some(apiToken)).getHeight()

        let headers = capturedHeaders.contents->Option.getOrThrow
        t.expect((
          result,
          headers->Dict.get("authorization"),
          headers->Dict.get("user-agent"),
        )).toEqual((
          Ok(123),
          Some(`Bearer ${apiToken}`),
          Some(`hyperindex/${Utils.EnvioPackage.value.version}`),
        ))
      },
    )
  })

  it("Throws with the token instructions when no token is configured", t => {
    t->toThrowErrorEqual(
      () => makeSource(~url="http://127.0.0.1:1", ~apiToken=None)->ignore,
      `An Envio API token is required for using HyperSync as a data-source.
Set the ENVIO_API_TOKEN environment variable in your .env file.
Learn more or get a free Envio API token at: https://envio.dev/app/api-tokens`,
    )
  })

  // A rejected token used to park the request on a promise that never settled,
  // which left the indexer silent and idle. It has to come back as a failure:
  // a token can be replaced without restarting, and the retry ramp is what gives
  // an operator the chance to.
  Async.it("Answers a 401 with a backoff so the caller keeps retrying", async t => {
    await withServer(
      (_req, res) => {
        res->writeHead(401)
        res->endWith("Unauthorized")
      },
      async url => {
        let {result} = await makeSource(~url, ~apiToken=Some(apiToken)).getHeight()

        t.expect(
          switch result {
          | Error(Backoff({backoffMillis: ?None})) => "backoff"
          | Ok(_) => "resolved"
          | Error(_) => "other failure"
          },
        ).toEqual("backoff")
      },
    )
  })
})
