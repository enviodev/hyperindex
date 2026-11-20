// https://github.com/enviodev/hyperindex/issues/1669
//
// A provider that throttles the first eth_getLogs requests in each of the ways
// providers do, then serves every later one. Throttling says nothing about how
// dense the range is, so the range each request asks for must not shrink.
let port = 18571
let url = `http://127.0.0.1:${port->Int.toString}`

let transfers: array<RpcE2eChain.transfer> = [
  {blockNumber: 100, value: 3, logIndex: 0},
  {blockNumber: 30_099, value: 4, logIndex: 1},
]

let rpcError = (request, ~code, ~message) =>
  JSON.stringify(
    JSON.Object(
      dict{
        "jsonrpc": JSON.String("2.0"),
        "id": request->Dict.getUnsafe("id"),
        "error": JSON.Object(
          dict{"code": JSON.Number(code->Int.toFloat), "message": JSON.String(message)},
        ),
      },
    ),
  )

// The first eth_getLogs requests, in order, and how each is refused.
let throttlingAnswers = [
  // geth-based endpoints: a JSON-RPC error under HTTP 429.
  request => (429, request->rpcError(~code=-32005, ~message="limit exceeded")),
  request => (429, request->rpcError(~code=-32005, ~message="limit exceeded")),
  request => (429, request->rpcError(~code=-32005, ~message="limit exceeded")),
  // A gateway in front of the node, answering for it.
  _ => (429, "Too Many Requests"),
  _ => (429, "Too Many Requests"),
  _ => (429, `{"message":"Too Many Requests"}`),
  // Throttling worded in the error alone, under HTTP 200.
  request => (200, request->rpcError(~code=-32005, ~message="limit exceeded")),
  request => (200, request->rpcError(~code=-32005, ~message="project ID request rate exceeded")),
  request => (
    200,
    request->rpcError(
      ~code=429,
      ~message="Your app has exceeded its compute units per second capacity",
    ),
  ),
]
let throttledRequests = ref(0)

let mock = RpcE2eChain.serveDuringSuite(() =>
  MockRpcServer.start(~port, ~handler=body => {
    let request = body->JSON.parseOrThrow->JSON.Decode.object->Option.getOrThrow
    let method = request->Dict.getUnsafe("method")->JSON.Decode.string->Option.getOrThrow
    switch throttlingAnswers->Array.get(throttledRequests.contents) {
    | Some(answer) if method == "eth_getLogs" =>
      throttledRequests := throttledRequests.contents + 1
      answer(request)
    | _ => (
        200,
        JSON.stringify(
          JSON.Object(
            dict{
              "jsonrpc": JSON.String("2.0"),
              "id": request->Dict.getUnsafe("id"),
              "result": RpcE2eChain.resultFor(
                ~transfers,
                ~height=40_000,
                ~method,
                ~params=request->Dict.getUnsafe("params"),
              ),
            },
          ),
        ),
      )
    }
  })
)

let _ = InternalTestIndexer.fromUserApi(
  ~configYaml=RpcE2eChain.configYaml(
    ~name="rpc-rate-limit",
    ~url,
    // Keep the wait after each throttled request short enough that the retries
    // are the only thing the test spends time on.
    ~extraRpc="\n      backoff_millis: 10",
  ),
  ~schema=RpcE2eChain.schema,
  ~handlers=RpcE2eChain.handlers,
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer, type Transfer, TestHelpers } from "envio";

const { Addresses } = TestHelpers;

describe("Indexing over a throttling RPC", () => {
  it("finishes the range once the provider stops throttling", async (t) => {
    const indexer = createTestIndexer();

    await indexer.process({ chains: { 1337: { startBlock: 100, endBlock: 30099 } } });

    const to = Addresses.mockAddresses[1];
    const expected: Transfer[] = [
      { id: "100-0", to, value: 3n },
      { id: "30099-1", to, value: 4n },
    ];
    t.expect([
      await indexer.Transfer.get("100-0"),
      await indexer.Transfer.get("30099-1"),
    ]).toEqual(expected);
  });
});
`,
)

let blockCount = range =>
  switch range->String.split("-")->Array.map(bound => bound->Int.fromString(~radix=16)) {
  | [Some(fromBlock), Some(toBlock)] => toBlock - fromBlock + 1
  | _ => JsError.throwWithMessage(`Unexpected eth_getLogs range ${range}`)
  }

// Every throttled request is asked again for the same 10,000 blocks, and the
// three pages the 30,000 blocks take are asked as wide as with no throttling.
Vitest.it("asks again for the same range after each throttled request", t => {
  t.expect((
    throttledRequests.contents,
    mock()->RpcE2eChain.logRanges->Array.map(blockCount),
  )).toEqual((
    throttlingAnswers->Array.length,
    Array.make(~length=throttlingAnswers->Array.length + 3, 10_000),
  ))
})
