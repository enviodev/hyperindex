// https://github.com/enviodev/hyperindex/issues/1691
let port = 18549
let url = `http://127.0.0.1:${port->Int.toString}`

let hyperSync = UnreachableHyperSyncServer.make()

let transfers: array<RpcE2eChain.transfer> = [
  {blockNumber: 100, value: 3, logIndex: 0},
  {blockNumber: 101, value: 4, logIndex: 1},
]

let _mock = RpcE2eChain.serveDuringSuite(() =>
  MockRpcServer.start(~port, ~handler=body => {
    let request = body->JSON.parseOrThrow->JSON.Decode.object->Option.getOrThrow
    (
      200,
      JSON.stringify(
        JSON.Object(
          dict{
            "jsonrpc": JSON.String("2.0"),
            "id": request->Dict.getUnsafe("id"),
            "result": RpcE2eChain.resultFor(
              ~transfers,
              ~height=105,
              ~method=request->Dict.getUnsafe("method")->JSON.Decode.string->Option.getOrThrow,
              ~params=request->Dict.getUnsafe("params"),
            ),
          },
        ),
      ),
    )
  })
)

let _ = InternalTestIndexer.fromUserApi(
  ~configYaml=`
name: hypersync-unreachable-e2e
rollback_on_reorg: false
chains:
  - id: 1337
    start_block: 100
    hypersync_config:
      url: ${hyperSync->UnreachableHyperSyncServer.url}
    rpc:
      url: ${url}
      for: fallback
    contracts:
      - name: Token
        address: "${RpcE2eChain.contractAddress}"
        events:
          - event: Transfer(address indexed from, address indexed to, uint256 value)
`,
  ~schema=RpcE2eChain.schema,
  ~handlers=RpcE2eChain.handlers,
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer, type Transfer, TestHelpers } from "envio";

const { Addresses } = TestHelpers;

describe("Indexing while the HyperSync address drops connections", () => {
  it("fails over to the RPC fallback and finishes the range", { timeout: 30_000 }, async (t) => {
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
