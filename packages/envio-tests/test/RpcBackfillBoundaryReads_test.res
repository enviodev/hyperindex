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

let blocksReadByNumber = (mock: MockRpcServer.t) =>
  mock.requests
  ->Array.filterMap(body => {
    let request = body->JSON.parseOrThrow->JSON.Decode.object->Option.getOrThrow
    switch request->Dict.getUnsafe("method")->JSON.Decode.string {
    | Some("eth_getBlockByNumber") =>
      request
      ->Dict.getUnsafe("params")
      ->JSON.Decode.array
      ->Option.getOrThrow
      ->Array.getUnsafe(0)
      ->RpcE2eChain.hexParam
      ->Some
    | _ => None
    }
  })
  ->Array.toSorted(Int.compare)

// The run's head is its end block, 600, so blocks 400 to 600 are checked one by
// one. Below them only the event's block is read: the pages 100-199, 200-299
// and 300-399 read none of their own boundaries.
Vitest.it("reads only the event's block below the checked head blocks", t => {
  t.expect({
    "pagesBelowCheckedBlocks": mock()->RpcE2eChain.logRanges->Array.slice(~start=0, ~end=3),
    "blocksRead": mock()->blocksReadByNumber,
  }).toEqual({
    "pagesBelowCheckedBlocks": ["0x64-0xc7", "0xc8-0x12b", "0x12c-0x18f"],
    "blocksRead": [105]->Array.concat(Array.fromInitializer(~length=201, i => 400 + i)),
  })
})
