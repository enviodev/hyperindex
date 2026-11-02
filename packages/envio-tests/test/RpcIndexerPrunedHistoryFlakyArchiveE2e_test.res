// https://github.com/enviodev/hyperindex/issues/714
//
// With the pruned node set aside, the fallback archive is the only source left
// for the range. An outage there long enough to put it in recovery must be
// waited out, not end the run for want of a working source.
let prunedPort = 18554
let archivePort = 18555

let pruned = RpcE2eChain.serveDuringSuite(() =>
  PrunedRpcChain.servePruned(~port=prunedPort, ~refused=["eth_getLogs", "eth_getBlockByNumber"])
)
let archive = RpcE2eChain.serveDuringSuite(() =>
  PrunedRpcChain.serveArchive(~port=archivePort, ~failedLogReads=4)
)

let _ = InternalTestIndexer.fromUserApi(
  ~configYaml=PrunedRpcChain.configYaml(
    ~name="rpc-pruned-history-flaky-archive-e2e",
    ~rpcs=[(prunedPort, "sync"), (archivePort, "fallback")],
  ),
  ~schema=RpcE2eChain.schema,
  ~handlers=RpcE2eChain.handlers,
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer, type Transfer, TestHelpers } from "envio";

const { Addresses } = TestHelpers;

describe("Indexing below a pruned RPC's base height over a flaky archive", () => {
  it("waits out the archive's outage", async (t) => {
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

Vitest.it("asks the pruned RPC once and retries the archive", t => {
  t.expect((pruned()->RpcE2eChain.logRanges, archive()->RpcE2eChain.logRanges)).toEqual((
    ["0x64-0x64"],
    ["0x64-0x64", "0x64-0x64", "0x64-0x64", "0x64-0x64", "0x64-0x64", "0x65-0x65"],
  ))
})
