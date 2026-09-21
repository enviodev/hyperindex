// The negative half of the RPC end-to-end coverage: the provider fails a page
// the way a real one does, with an HTTP 502 and a body that isn't JSON-RPC at
// all, and the indexer has to come back and finish the range anyway.
//
// The transport failure path is otherwise only asserted at the client, against
// a `getHeight` call. Nothing pinned that a failed page is retried by the loop
// rather than skipped, which would silently lose every event in the range.
let port = 18546
let url = `http://127.0.0.1:${port->Int.toString}`

let transfers: array<RpcE2eChain.transfer> = [
  {blockNumber: 100, value: 3, logIndex: 0},
  {blockNumber: 101, value: 4, logIndex: 1},
]

// The provider fails the first page and serves every later one, so the range
// can only complete if the loop retried it.
let servedFailure = ref(false)

let server = ref(None)
let mock = () =>
  server.contents->Option.getOrThrow(~message="the mock RPC server was never started")

Vitest.Async.beforeAll(async () => {
  let started = await MockRpcServer.start(~port, ~handler=body => {
    let request = body->JSON.parseOrThrow->JSON.Decode.object->Option.getOrThrow
    let method = request->Dict.getUnsafe("method")->JSON.Decode.string->Option.getOrThrow
    if method == "eth_getLogs" && !servedFailure.contents {
      servedFailure := true
      (502, "upstream exploded")
    } else {
      (
        200,
        JSON.stringify(
          JSON.Object(
            dict{
              "jsonrpc": JSON.String("2.0"),
              "id": request->Dict.getUnsafe("id"),
              "result": RpcE2eChain.resultFor(
                ~transfers,
                ~height=105,
                ~method,
                ~params=request->Dict.getUnsafe("params"),
              ),
            },
          ),
        ),
      )
    }
  })
  server := Some(started)
})

Vitest.Async.afterAll(async () => {
  switch server.contents {
  | Some(started) => await started.closeAsync()
  | None => ()
  }
})

let _ = InternalTestIndexer.fromUserApi(
  ~configYaml=RpcE2eChain.configYaml(
    ~name="rpc-indexer-retry-e2e",
    ~url,
    // Keep the wait after the failed page short enough that the retry is the
    // only thing the test spends time on.
    ~extraRpc="\n      backoff_millis: 10",
  ),
  ~schema=RpcE2eChain.schema,
  ~handlers=RpcE2eChain.handlers,
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer, type Transfer, TestHelpers } from "envio";

const { Addresses } = TestHelpers;

describe("Indexing over a failing RPC", () => {
  it("finishes the range after the provider fails a page", async (t) => {
    const indexer = createTestIndexer();

    await indexer.process({ chains: { 1337: { startBlock: 100, endBlock: 101 } } });

    const to = Addresses.mockAddresses[1];
    const expected: Transfer[] = [
      { id: "100-0", to, value: 3n },
      { id: "101-1", to, value: 4n },
    ];
    t.expect([
      await indexer.Transfer.get("100-0"),
      await indexer.Transfer.get("101-1"),
    ]).toEqual(expected);
  });
});
`,
)

// Entities alone would also be satisfied by a provider that never failed, so
// pin the pages themselves: the wide page the provider refused, then the two
// narrowed ones the shrunk interval re-read it as.
Vitest.it("narrows and retries the range the provider failed", t => {
  t.expect((servedFailure.contents, mock()->RpcE2eChain.logRanges)).toEqual((
    true,
    ["0x64-0x65", "0x64-0x64", "0x65-0x65"],
  ))
})
