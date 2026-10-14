// A stand-in for the sidecar's internal server (127.0.0.1, port 0): records
// every request the indexer sends and answers the way the runtime does, unless
// the test says otherwise.
type request = {path: string, body: JSON.t}
// `text`, when given, is sent as is instead of `body` (the runtime's /metrics).
type reply = {status: int, body: JSON.t, text?: string}

type t = {
  url: string,
  requests: array<request>,
  close: unit => promise<unit>,
}

type callsBody = {calls: array<{"id": string}>}

// The runtime's answers (src/sidecar/runtime.ts): every call accepted, a
// rollback that dropped nothing.
let runtimeReply = async (request: request) =>
  switch request.path {
  | "/envio/calls" =>
    let {calls} = request.body->(Utils.magic: JSON.t => callsBody)
    {
      status: 202,
      body: {"accepted": calls->Array.map(call => call["id"]), "rejected": []}->Utils.magic,
    }
  | _ => {status: 200, body: {"dropped": 0}->Utils.magic}
  }

let start = (~respond: request => promise<reply>=runtimeReply): promise<t> => {
  let requests = []
  let server = MockRpcServer.createServer((req, res) => {
    let body = ref("")
    req->MockRpcServer.setEncoding("utf8")
    req->MockRpcServer.onData(chunk => body := body.contents ++ chunk)
    req->MockRpcServer.onEnd(() => {
      let request = {
        path: req->MockRpcServer.reqUrl,
        // GET /readyz and /metrics come without a body.
        body: body.contents === "" ? JSON.Null : body.contents->JSON.parseOrThrow,
      }
      requests->Array.push(request)->ignore
      let _ = respond(request)->Promise.thenResolve(
        reply =>
          switch reply.text {
          | Some(text) =>
            res->MockRpcServer.writeHead(reply.status, dict{"content-type": "text/plain"})
            res->MockRpcServer.end_(text)
          | None =>
            res->MockRpcServer.writeHead(reply.status, dict{"content-type": "application/json"})
            res->MockRpcServer.end_(reply.body->JSON.stringify)
          },
      )
    })
  })
  Promise.make((resolve, _) =>
    server->MockRpcServer.listenOnHost(0, "127.0.0.1", () =>
      resolve({
        url: `http://127.0.0.1:${(server->MockRpcServer.address).port->Int.toString}`,
        requests,
        close: () =>
          Promise.make(
            (resolve, _) => {
              server->MockRpcServer.closeAllConnections
              server->MockRpcServer.close(() => resolve())
            },
          ),
      })
    )
  )
}

// A port nothing listens on: a sidecar that is down.
let down = async () => {
  let sidecar = await start()
  await sidecar.close()
  sidecar.url
}
