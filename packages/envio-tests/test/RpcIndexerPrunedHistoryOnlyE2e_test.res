// https://github.com/enviodev/hyperindex/issues/714
//
// With no other source to move to, a node that doesn't hold the range has to
// fail the run with its reason rather than retry the same refusal forever.
let port = 18553

let pruned = RpcE2eChain.serveDuringSuite(() =>
  PrunedRpcChain.servePruned(~port, ~refused=["eth_getLogs", "eth_getBlockByNumber"])
)

let _ = InternalTestIndexer.fromUserApi(
  ~configYaml=PrunedRpcChain.configYaml(~name="rpc-pruned-history-only-e2e", ~ports=[port]),
  ~schema=RpcE2eChain.schema,
  ~handlers=RpcE2eChain.handlers,
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("Indexing below the base height of the only RPC", () => {
  it("fails the run with the provider's reason", async (t) => {
    const indexer = createTestIndexer();

    let outcome = "resolved";
    try {
      await indexer.process({ chains: { 1337: { startBlock: 100, endBlock: 101 } } });
    } catch (error) {
      outcome = error === null ? "rejected without a reason" : String(error);
    }

    t.expect([outcome, await indexer.Transfer.get("100-0")]).toEqual([
      "Error: The indexer doesn't have data-sources which can serve the block range. The RPC doesn't hold the requested blocks: height is not available (requested height: 100, base height: 200)",
      undefined,
    ]);
  });
});
`,
)

Vitest.it("asks the pruned RPC once", t => {
  t.expect(pruned()->RpcE2eChain.logRanges).toEqual(["0x64-0x65"])
})
