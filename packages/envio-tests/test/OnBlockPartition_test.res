// A block handler selecting fields is fetched apart from the wildcard events:
// sharing their queries would cap every log page at the blocks the handler can
// afford to read one request at a time.
let port = 18550
let url = `http://127.0.0.1:${port->Int.toString}`

let mock = RpcE2eChain.serveDuringSuite(() =>
  MockRpcServer.makeWithParams(~port, ~getResult=(~method, ~params) =>
    RpcE2eChain.resultFor(
      ~transfers=[{blockNumber: 300, value: 3, logIndex: 0}],
      ~height=400,
      ~method,
      ~params,
    )
  )
)

let _ = InternalTestIndexer.fromUserApi(
  ~configYaml=RpcE2eChain.configYaml(~name="on-block-partition", ~url),
  ~schema=RpcE2eChain.schema ++ `
type BlockSeen {
  id: ID!
  timestamp: Int!
}
`,
  ~handlers=`
import { indexer } from "envio";

indexer.onEvent(
  { contract: "Token", event: "Transfer", wildcard: true },
  async ({ event, context }) => {
    context.Transfer.set({
      id: \`\${event.block.number}-\${event.logIndex}\`,
      to: event.params.to,
      value: event.params.value,
    });
  },
);

indexer.onBlock(
  { name: "everyBlock", fields: { block: ["timestamp"] } },
  async ({ block, context }) => {
    context.BlockSeen.set({ id: String(block.number), timestamp: block.timestamp });
  },
);
`,
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer, TestHelpers } from "envio";

const { Addresses } = TestHelpers;

describe("A block handler selecting fields beside wildcard events", () => {
  it("runs on every block and indexes the events", async (t) => {
    const indexer = createTestIndexer();

    await indexer.process({ chains: { 1337: { startBlock: 100, endBlock: 349 } } });

    t.expect({
      transfer: await indexer.Transfer.get("300-0"),
      blocks: (await indexer.BlockSeen.getAll()).sort((a, b) => Number(a.id) - Number(b.id)),
    }).toEqual({
      transfer: { id: "300-0", to: Addresses.mockAddresses[1], value: 3n },
      // The mock chain's block timestamp is its number.
      blocks: Array.from({ length: 250 }, (_, i) => ({ id: String(100 + i), timestamp: 100 + i })),
    });
  });
});
`,
)

Vitest.it("reads the events in one log page", t => {
  t.expect(mock()->RpcE2eChain.logRanges).toEqual(["0x64-0x15d"])
})
