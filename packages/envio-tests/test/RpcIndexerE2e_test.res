// The rung the RPC source was missing: a real user config whose chain names an
// RPC url, real handler source, and the whole indexer loop running against a
// real HTTP JSON-RPC server. Every other RPC test stops at the source or at the
// client, so nothing asserted that logs served over RPC become the entities a
// user reads back.
//
// The server binds a fixed port because `fromUserApi` builds its config YAML
// synchronously while vitest collects, long before an async listen could report
// a random one.
let port = 18545
let url = `http://127.0.0.1:${port->Int.toString}`

// Two transfers in different blocks, with different log indexes, so a page that
// collapsed them would show up as a missing entity rather than a wrong total.
let transfers: array<RpcE2eChain.transfer> = [
  {blockNumber: 100, value: 3, logIndex: 0},
  {blockNumber: 101, value: 4, logIndex: 1},
]

let server = ref(None)
let mock = () =>
  server.contents->Option.getOrThrow(~message="the mock RPC server was never started")

Vitest.Async.beforeAll(async () => {
  let started = await MockRpcServer.makeWithParams(~port, ~getResult=(~method, ~params) =>
    RpcE2eChain.resultFor(~transfers, ~height=105, ~method, ~params)
  )
  server := Some(started)
})

Vitest.Async.afterAll(async () => {
  switch server.contents {
  | Some(started) => await started.closeAsync()
  | None => ()
  }
})

let _ = InternalTestIndexer.fromUserApi(
  ~configYaml=RpcE2eChain.configYaml(~name="rpc-indexer-e2e", ~url),
  ~schema=RpcE2eChain.schema,
  ~handlers=RpcE2eChain.handlers,
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer, type Transfer, TestHelpers } from "envio";

const { Addresses } = TestHelpers;

describe("Indexing over RPC", () => {
  it("turns logs served over RPC into entities", async (t) => {
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

// The entity assertion above cannot tell a real fetch from a simulated one, so
// pin what actually went over the wire: one eth_getLogs covering the range, and
// a read of each block the page referenced.
Vitest.it("read the range over RPC", t => {
  t.expect(mock()->RpcE2eChain.callSummary).toEqual([
    "eth_getBlockByNumber",
    "eth_getBlockByNumber",
    `eth_getLogs "0x64"-"0x65"`,
  ])
})
