// https://github.com/enviodev/hyperindex/issues/1774
// A log that carries its block's timestamp, as geth 1.16+ serves it, answers an
// event's default block fields on its own, so the event's block is not read.
let port = 18553
let url = `http://127.0.0.1:${port->Int.toString}`

let transfers: array<RpcE2eChain.transfer> = [{blockNumber: 105, value: 3, logIndex: 0}]

let mock = RpcE2eChain.serveDuringSuite(() =>
  MockRpcServer.makeWithParams(~port, ~getResult=(~method, ~params) =>
    RpcE2eChain.resultFor(
      ~transfers,
      ~height=1_000_000,
      ~logsWithBlockTimestamp=true,
      ~method,
      ~params,
    )
  )
)

let _ = InternalTestIndexer.fromUserApi(
  ~configYaml=RpcE2eChain.configYaml(
    ~name="rpc-log-block-timestamp",
    ~url,
    ~extraRpc=`
      initial_block_interval: 100
      interval_ceiling: 100`,
  ),
  ~schema=`
type Transfer {
  id: ID!
  blockHash: String!
  blockTimestamp: Int!
}
`,
  ~handlers=`
import { indexer } from "envio";

indexer.onEvent({ contract: "Token", event: "Transfer" }, async ({ event, context }) => {
  context.Transfer.set({
    id: \`\${event.block.number}-\${event.logIndex}\`,
    blockHash: event.block.hash,
    blockTimestamp: event.block.timestamp,
  });
});
`,
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer, type Transfer } from "envio";

describe("Logs carrying their block's timestamp", () => {
  it("serve the event's block fields", async (t) => {
    const indexer = createTestIndexer();

    await indexer.process({ chains: { 1337: { startBlock: 100, endBlock: 600 } } });

    const expected: Transfer = {
      id: "105-0",
      blockHash: "${105->RpcE2eChain.blockHash}",
      blockTimestamp: 105,
    };
    t.expect(await indexer.Transfer.get("105-0")).toEqual(expected);
  });
});
`,
)

// The run's head is its end block, 600, so blocks 400 to 600 are checked one by
// one. Block 105 is not read: its log carried everything the event selected.
Vitest.it("reads no block below the checked head blocks", t => {
  t.expect(mock()->RpcE2eChain.distinctBlocksRead).toEqual(
    Array.fromInitializer(~length=201, i => 400 + i),
  )
})
