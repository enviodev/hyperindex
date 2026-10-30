// https://github.com/enviodev/hyperindex/issues/714
//
// Some public RPCs only hold blocks above a base height and answer anything
// older with an error. Waiting or narrowing the range cannot change that answer,
// so the query has to move to another source straight away.
//
// The node here serves the logs and refuses only the blocks behind them, which is
// how the issue reported it: the refusal reaches the page from `eth_getBlockByNumber`.
let prunedPort = 18551
let archivePort = 18552

let pruned = RpcE2eChain.serveDuringSuite(() =>
  PrunedRpcChain.servePruned(~port=prunedPort, ~refused=["eth_getBlockByNumber"])
)
let archive = RpcE2eChain.serveDuringSuite(() => PrunedRpcChain.serveArchive(~port=archivePort))

let _ = InternalTestIndexer.fromUserApi(
  ~configYaml=PrunedRpcChain.configYaml(
    ~name="rpc-pruned-history-e2e",
    ~ports=[prunedPort, archivePort],
  ),
  ~schema=RpcE2eChain.schema,
  ~handlers=RpcE2eChain.handlers,
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer, type Transfer, TestHelpers } from "envio";

const { Addresses } = TestHelpers;

describe("Indexing below a pruned RPC's base height", () => {
  it("reads the range from the other RPC", async (t) => {
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

// The pruned node is asked once and then left alone: no backoff retries, and no
// narrowed ranges that would only be refused the same way.
Vitest.it("asks the pruned RPC once and reads the range from the archive one", t => {
  t.expect((pruned()->RpcE2eChain.callSummary, archive()->RpcE2eChain.logRanges)).toEqual((
    ["eth_getBlockByNumber", "eth_getBlockByNumber", `eth_getLogs "0x64"-"0x65"`],
    ["0x64-0x65"],
  ))
})
