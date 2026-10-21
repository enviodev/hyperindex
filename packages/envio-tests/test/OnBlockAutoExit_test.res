// Without an endBlock, `process` stops after the first block with events. A
// block handler selecting fields gets its blocks from the source, alongside the
// events, yet a block it runs on is no event block.
let port = 18549
let url = `http://127.0.0.1:${port->Int.toString}`

let _ = RpcE2eChain.serveDuringSuite(() =>
  MockRpcServer.makeWithParams(~port, ~getResult=(~method, ~params) =>
    RpcE2eChain.resultFor(
      ~transfers=[{blockNumber: 103, value: 3, logIndex: 0}],
      ~height=110,
      ~method,
      ~params,
    )
  )
)

let _ = InternalTestIndexer.fromUserApi(
  ~configYaml=RpcE2eChain.configYaml(~name="on-block-auto-exit", ~url),
  ~schema=RpcE2eChain.schema ++ `
type BlockSeen {
  id: ID!
  timestamp: Int!
}
`,
  ~handlers=RpcE2eChain.handlers ++ `
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

describe("Auto-exit with a block handler selecting fields", () => {
  it("runs up to the first block with events", async (t) => {
    const indexer = createTestIndexer();

    await indexer.process({ chains: { 1337: { startBlock: 100 } } });

    t.expect({
      transfer: await indexer.Transfer.get("103-0"),
      blocks: (await indexer.BlockSeen.getAll()).map((b) => b.id).sort(),
    }).toEqual({
      transfer: { id: "103-0", to: Addresses.mockAddresses[1], value: 3n },
      blocks: ["100", "101", "102", "103"],
    });
  });
});
`,
)
