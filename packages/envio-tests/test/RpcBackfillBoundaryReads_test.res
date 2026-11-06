// https://github.com/enviodev/hyperindex/issues/1782
// A page below the checked head blocks has no block a reorg or a lagging node
// could still reach, so it reads only the blocks its events need.
let port = 18551
let url = `http://127.0.0.1:${port->Int.toString}`

let transfers: array<RpcE2eChain.transfer> = [{blockNumber: 105, value: 3, logIndex: 0}]

let mock = RpcE2eChain.serveDuringSuite(() =>
  MockRpcServer.makeWithParams(~port, ~getResult=(~method, ~params) =>
    RpcE2eChain.resultFor(~transfers, ~height=1_000_000, ~method, ~params)
  )
)

let _ = InternalTestIndexer.fromUserApi(
  ~configYaml=RpcE2eChain.configYaml(
    ~name="rpc-backfill-boundary-reads",
    ~url,
    ~extraRpc=`
      initial_block_interval: 100
      interval_ceiling: 100`,
  ),
  ~schema=RpcE2eChain.schema,
  ~handlers=RpcE2eChain.handlers,
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer, type Transfer, TestHelpers } from "envio";

const { Addresses } = TestHelpers;

describe("Backfilling over RPC below the checked head blocks", () => {
  it("indexes the range's one event", async (t) => {
    const indexer = createTestIndexer();

    await indexer.process({ chains: { 1337: { startBlock: 100, endBlock: 600 } } });

    const expected: Transfer = { id: "105-0", to: Addresses.mockAddresses[1], value: 3n };
    t.expect(await indexer.Transfer.get("105-0")).toEqual(expected);
  });
});
`,
)

// The run's head is its end block, 600, so blocks 500 to 600 are checked one by
// one. Below them only the event's block is read: the pages 100-199 to 400-499
// read none of their own boundaries.
Vitest.it("reads only the event's block below the checked head blocks", t => {
  t.expect(mock()->RpcE2eChain.distinctBlocksRead).toEqual(
    [105]->Array.concat(Array.fromInitializer(~length=101, i => 500 + i)),
  )
})
