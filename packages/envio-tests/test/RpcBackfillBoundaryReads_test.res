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

let firstCheckedBlock = 400

// Pages are read concurrently and a slow one can be retried, so the request
// order and repeats depend on timing; which blocks and ranges are read does not.
let distinctAscending = numbers =>
  Set.fromArray(numbers)->Set.values->Iterator.toArray->Array.toSorted(Int.compare)

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
  ->distinctAscending

let pageStartsBelowCheckedBlocks = (mock: MockRpcServer.t) =>
  mock
  ->RpcE2eChain.logRanges
  ->Array.map(range =>
    range->String.split("-")->Array.getUnsafe(0)->JSON.String->RpcE2eChain.hexParam
  )
  ->Array.filter(fromBlock => fromBlock < firstCheckedBlock)
  ->distinctAscending

// The run's head is its end block, 600, so blocks 400 to 600 are checked one by
// one. Below them only the event's block is read: the pages 100-199, 200-299
// and 300-399 read none of their own boundaries.
Vitest.it("reads only the event's block below the checked head blocks", t => {
  t.expect({
    "pageStartsBelowCheckedBlocks": mock()->pageStartsBelowCheckedBlocks,
    "blocksRead": mock()->blocksReadByNumber,
  }).toEqual({
    "pageStartsBelowCheckedBlocks": [100, 200, 300],
    "blocksRead": [105]->Array.concat(
      Array.fromInitializer(~length=201, i => firstCheckedBlock + i),
    ),
  })
})
