// https://github.com/enviodev/hyperindex/issues/1669
//
// A provider that throttles the first eth_getLogs with HTTP 429 and
// `Retry-After: 1`, then serves everything. The configured backoff is far
// shorter than the provider's reset, so only a retry that waited what the
// provider asked can arrive a second later.
let port = 18573
let url = `http://127.0.0.1:${port->Int.toString}`

let transfers: array<RpcE2eChain.transfer> = [
  {blockNumber: 100, value: 3, logIndex: 0},
  {blockNumber: 10_099, value: 4, logIndex: 1},
]

let logRequests: array<(float, string)> = []

let blockRange = (request: MockRpcServer.rpcRequest) => {
  let filter =
    request.params
    ->JSON.Decode.array
    ->Option.getOrThrow
    ->Array.getUnsafe(0)
    ->JSON.Decode.object
    ->Option.getOrThrow
  let bound = name => filter->Dict.get(name)->Option.flatMap(JSON.Decode.string)
  switch (bound("fromBlock"), bound("toBlock")) {
  | (Some(fromBlock), Some(toBlock)) => `${fromBlock}-${toBlock}`
  | _ => "block hash"
  }
}

// Real time: the indexer under test runs on the real clock, so the wait is
// measured from when each request reached the provider.
let recordLogRequest = request => logRequests->Array.push((Date.now(), request->blockRange))->ignore

let served = (request: MockRpcServer.rpcRequest): MockRpcServer.reply => RpcResult(
  RpcE2eChain.resultFor(~transfers, ~height=20_000, ~method=request.method, ~params=request.params),
)

// Every method but the first eth_getLogs is served for as long as the run
// asks, so the throttling is the only thing the provider does to it.
let _mock = RpcE2eChain.serveDuringSuite(() =>
  MockRpcServer.startInternal(
    ~name="throttling provider with Retry-After",
    ~port,
    ~calls=[
      MockRpcServer.expectCall(
        ~label="throttled eth_getLogs",
        ~method="eth_getLogs",
        ~reply=Dynamic(
          request => {
            request->recordLogRequest
            RawHttp({
              status: 429,
              headers: dict{"Retry-After": "1"},
              body: `{"jsonrpc":"2.0","id":1,"error":{"code":-32005,"message":"limit exceeded"}}`,
            })
          },
        ),
      ),
      MockRpcServer.expectCall(
        ~label="served eth_getLogs",
        ~method="eth_getLogs",
        ~times=1_000_000,
        ~reply=Dynamic(
          request => {
            request->recordLogRequest
            served(request)
          },
        ),
      ),
      MockRpcServer.expectCall(~method="eth_blockNumber", ~times=1_000_000, ~reply=Dynamic(served)),
      MockRpcServer.expectCall(
        ~method="eth_getBlockByNumber",
        ~times=1_000_000,
        ~reply=Dynamic(served),
      ),
    ],
  )
)

let _ = InternalTestIndexer.fromUserApi(
  ~configYaml=RpcE2eChain.configYaml(
    ~name="rpc-retry-after",
    ~url,
    ~extraRpc="\n      backoff_millis: 10",
  ),
  ~schema=RpcE2eChain.schema,
  ~handlers=RpcE2eChain.handlers,
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer, type Transfer, TestHelpers } from "envio";

const { Addresses } = TestHelpers;

describe("Indexing over an RPC that sends Retry-After", () => {
  it("finishes the range after waiting out the provider's reset", async (t) => {
    const indexer = createTestIndexer();

    await indexer.process({ chains: { 1337: { startBlock: 100, endBlock: 10099 } } });

    const to = Addresses.mockAddresses[1];
    const expected: Transfer[] = [
      { id: "100-0", to, value: 3n },
      { id: "10099-1", to, value: 4n },
    ];
    t.expect([
      await indexer.Transfer.get("100-0"),
      await indexer.Transfer.get("10099-1"),
    ]).toEqual(expected);
  });
});
`,
)

// The retry asks the range the provider refused, no sooner than the second it
// was told to wait. Only a lower bound: a slow runner may wait longer.
Vitest.it("retries the same range once the provider's Retry-After has passed", t => {
  let (throttledAt, throttledRange) = logRequests->Array.getUnsafe(0)
  let (retriedAt, retriedRange) = logRequests->Array.getUnsafe(1)
  t.expect((throttledRange, retriedRange, retriedAt -. throttledAt >= 1000.)).toEqual((
    "0x64-0x2773",
    "0x64-0x2773",
    true,
  ))
})
