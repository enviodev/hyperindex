open Vitest

type httpResponse = {status: int, body: string}

let post: (string, string, dict<string>) => promise<httpResponse> = %raw(`async function(url, body, headers) {
  var response = await fetch(url, {
    method: "POST",
    headers: Object.assign({"content-type": "application/json"}, headers),
    body: body
  });
  return {status: response.status, body: await response.text()};
}`)

let requestBody = (~method, ~params, ~id=1) =>
  JSON.stringify(
    JSON.Object(
      Dict.fromArray([
        ("method", JSON.String(method)),
        ("params", params),
        ("id", JSON.Number(id->Int.toFloat)),
        ("jsonrpc", JSON.String("2.0")),
      ]),
    ),
  )

let resultOf = (response: httpResponse) =>
  response.body
  ->JSON.parseOrThrow
  ->JSON.Decode.object
  ->Option.flatMap(Dict.get(_, "result"))

describe("MockRpcServer scripted scenarios", () => {
  Async.it("matches structurally equal requests in any order and records a transcript", async t => {
    let transcript = await MockRpcServer.withScenario(
      ~name="unordered structural matching",
      ~calls=[
        MockRpcServer.expectCall(
          ~label="height",
          ~method="eth_blockNumber",
          ~params=JSON.Array([]),
          ~reply=RpcResult(JSON.String("0x64")),
        ),
        MockRpcServer.expectCall(
          ~label="logs",
          ~method="eth_getLogs",
          ~params=JSON.parseOrThrow(`[{"topics":[["0xabc"]],"fromBlock":"0x1","toBlock":"0x2"}]`),
          ~reply=RpcResult(JSON.Array([])),
        ),
      ],
      async mock => {
        // Deliberately send the second declaration first. Object key order also
        // differs from the inline expectation and must not affect matching.
        let logs = await post(
          mock.url,
          requestBody(
            ~method="eth_getLogs",
            ~params=JSON.parseOrThrow(`[{"toBlock":"0x2","fromBlock":"0x1","topics":[["0xabc"]]}]`),
          ),
          Dict.make(),
        )
        let height = await post(
          mock.url,
          requestBody(~method="eth_blockNumber", ~params=JSON.Array([])),
          Dict.make(),
        )
        t.expect((logs.status, height->resultOf)).toEqual((200, Some(JSON.String("0x64"))))
        mock.transcript()
      },
    )

    t.expect(transcript->Array.map(entry => entry.matchedLabel)).toEqual([
      Some("logs"),
      Some("height"),
    ])
  })

  Async.it("consumes repeated identical matchers in declaration order", async t => {
    let results = await MockRpcServer.withScenario(
      ~name="sequential identical matcher",
      ~calls=[
        MockRpcServer.expectCall(
          ~label="first height",
          ~method="eth_blockNumber",
          ~params=JSON.Array([]),
          ~reply=RpcResult(JSON.String("0x1")),
        ),
        MockRpcServer.expectCall(
          ~label="second height",
          ~method="eth_blockNumber",
          ~params=JSON.Array([]),
          ~reply=RpcResult(JSON.String("0x2")),
        ),
      ],
      async mock => {
        let first = await post(
          mock.url,
          requestBody(~method="eth_blockNumber", ~params=JSON.Array([])),
          Dict.make(),
        )
        let second = await post(
          mock.url,
          requestBody(~method="eth_blockNumber", ~params=JSON.Array([])),
          Dict.make(),
        )
        (first->resultOf, second->resultOf)
      },
    )

    t.expect(results).toEqual((Some(JSON.String("0x1")), Some(JSON.String("0x2"))))
  })

  Async.it("matches requested header subsets and can delay a reply", async t => {
    let response = await MockRpcServer.withScenario(
      ~name="headers and delay",
      ~calls=[
        MockRpcServer.expectCall(
          ~method="eth_blockNumber",
          ~params=JSON.Array([]),
          ~headers=Dict.fromArray([("authorization", "Bearer pin")]),
          ~reply=Delayed({millis: 5, reply: RpcResult(JSON.String("0x3"))}),
        ),
      ],
      async mock =>
        await post(
          mock.url,
          requestBody(~method="eth_blockNumber", ~params=JSON.Array([])),
          Dict.fromArray([("Authorization", "Bearer pin"), ("X-Ignored", "extra")]),
        ),
    )

    t.expect((response.status, response->resultOf)).toEqual((200, Some(JSON.String("0x3"))))
  })

  Async.it("reports both unexpected and unconsumed calls without throwing in the HTTP callback", async t => {
    let mock = await MockRpcServer.startScenario(
      ~name="verification report",
      ~calls=[
        MockRpcServer.expectCall(
          ~label="expected height",
          ~method="eth_blockNumber",
          ~params=JSON.Array([]),
          ~reply=RpcResult(JSON.String("0x1")),
        ),
      ],
    )

    let response = await post(
      mock.url,
      requestBody(~method="eth_chainId", ~params=JSON.Array([])),
      Dict.make(),
    )
    let verification = mock.verify()
    await mock.closeAsync()

    t.expect((response.status, verification.failures->Array.length, verification.pending)).toEqual((
      500,
      1,
      ["expected height"],
    ))
  })

  Async.it("force-closes a deliberately hanging response without leaving an open handle", async t => {
    let mock = await MockRpcServer.startScenario(
      ~name="hanging response cleanup",
      ~calls=[
        MockRpcServer.expectCall(
          ~method="eth_blockNumber",
          ~params=JSON.Array([]),
          ~reply=NoResponse,
        ),
      ],
    )
    let pendingRequest = post(
      mock.url,
      requestBody(~method="eth_blockNumber", ~params=JSON.Array([])),
      Dict.make(),
    )
    await Utils.delay(5)
    let verification = mock.verify()
    await mock.closeAsync()
    let requestWasRejected = try {
      let _ = await pendingRequest
      false
    } catch {
    | _ => true
    }

    t.expect((verification, requestWasRejected)).toEqual((
      {MockRpcServer.failures: [], pending: []},
      true,
    ))
  })

  Async.it("closes the server and preserves an exception thrown by the test callback", async t => {
    let message = try {
      let _ = await MockRpcServer.withScenario(
        ~name="callback failure cleanup",
        ~calls=[],
        async _mock => JsError.throwWithMessage("intentional test failure"),
      )
      None
    } catch {
    | JsExn(e) => e->JsExn.message
    }

    t.expect(message).toEqual(Some("intentional test failure"))
  })
})
