// A contract with a thousand addresses would send all of them with every
// eth_getLogs, block after block at the head. A query that spans only a few
// blocks asks for the event signatures alone and drops the logs of emitters the
// indexer doesn't track itself.
let port = 18549
let url = `http://127.0.0.1:${port->Int.toString}`

let addresses = RpcE2eChain.trackedAddresses(1_000)

let transfers: array<RpcE2eChain.transfer> = [
  {blockNumber: 100, value: 3, logIndex: 0},
  {
    blockNumber: 101,
    value: 4,
    logIndex: 1,
    emitter: "0x2222222222222222222222222222222222222222",
  },
  {blockNumber: 101, value: 5, logIndex: 2, emitter: addresses->Array.getUnsafe(999)},
]

let mock = RpcE2eChain.serveDuringSuite(() =>
  MockRpcServer.makeWithParams(~port, ~getResult=(~method, ~params) =>
    RpcE2eChain.resultFor(~transfers, ~height=105, ~method, ~params)
  )
)

let _ = InternalTestIndexer.fromUserApi(
  ~configYaml=RpcE2eChain.configYaml(~name="rpc-address-free-e2e", ~url, ~addresses),
  ~schema=RpcE2eChain.schema,
  ~handlers=RpcE2eChain.handlers,
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer, type Transfer, TestHelpers } from "envio";

const { Addresses } = TestHelpers;

describe("Indexing many addresses over RPC near the head", () => {
  it("keeps only the logs of tracked addresses", async (t) => {
    const indexer = createTestIndexer();

    await indexer.process({ chains: { 1337: { startBlock: 100, endBlock: 101 } } });

    const to = Addresses.mockAddresses[1];
    const expected: (Transfer | undefined)[] = [
      { id: "100-0", to, value: 3n },
      undefined,
      { id: "101-2", to, value: 5n },
    ];
    t.expect([
      await indexer.Transfer.get("100-0"),
      await indexer.Transfer.get("101-1"),
      await indexer.Transfer.get("101-2"),
    ]).toEqual(expected);
  });
});
`,
)

Vitest.it("asked for the range without an address filter", t => {
  t.expect(mock()->RpcE2eChain.logFilters).toEqual(["0x64-0x65 addresses=0"])
})
