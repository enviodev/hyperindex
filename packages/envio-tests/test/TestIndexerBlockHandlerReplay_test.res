// A process() call that names no startBlock begins at the chain's start block,
// so a block handler runs on every block between it and the one event the test
// is about, each run adding an entry to `changes`.
let port = 18554
let url = `http://127.0.0.1:${port->Int.toString}`

let _ = RpcE2eChain.serveDuringSuite(() =>
  MockRpcServer.makeWithParams(~port, ~getResult=(~method, ~params) =>
    RpcE2eChain.resultFor(
      ~transfers=[{blockNumber: 1100, value: 3, logIndex: 0}],
      ~height=1110,
      ~method,
      ~params,
    )
  )
)

let _ = InternalTestIndexer.fromUserApi(
  ~configYaml=RpcE2eChain.configYaml(~name="test-indexer-block-handler-replay", ~url),
  ~schema=RpcE2eChain.schema ++ `
type BlockHandlerRuns {
  id: ID!
  count: Int!
  firstBlock: Int!
  lastBlock: Int!
}
`,
  ~handlers=RpcE2eChain.handlers ++ `
indexer.onBlock({ name: "everyBlock" }, async ({ block, context }) => {
  const runs = await context.BlockHandlerRuns.get("everyBlock");
  context.BlockHandlerRuns.set({
    id: "everyBlock",
    count: (runs?.count ?? 0) + 1,
    firstBlock: runs?.firstBlock ?? block.number,
    lastBlock: block.number,
  });
});
`,
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer, TestHelpers } from "envio";

const { Addresses } = TestHelpers;

describe("A block handler in a test of one event", () => {
  it("runs only on the simulated event's block", async (t) => {
    const indexer = createTestIndexer();

    const result = await indexer.process({
      chains: {
        1337: {
          simulate: [
            {
              contract: "Token",
              event: "Transfer",
              params: { from: Addresses.mockAddresses[2], to: Addresses.mockAddresses[1], value: 3n },
              block: { number: 1100 },
            },
          ],
        },
      },
    });

    t.expect({
      changes: result.changes.length,
      blockHandlerRuns: await indexer.BlockHandlerRuns.get("everyBlock"),
    }).toEqual({
      changes: 1,
      blockHandlerRuns: { id: "everyBlock", count: 1, firstBlock: 1100, lastBlock: 1100 },
    });
  });

  it("runs only on the first block with events in auto-exit mode", async (t) => {
    const indexer = createTestIndexer();

    const result = await indexer.process({ chains: { 1337: {} } });

    t.expect({
      changes: result.changes.length,
      blockHandlerRuns: await indexer.BlockHandlerRuns.get("everyBlock"),
    }).toEqual({
      changes: 1,
      blockHandlerRuns: { id: "everyBlock", count: 1, firstBlock: 1100, lastBlock: 1100 },
    });
  });

});
`,
)
