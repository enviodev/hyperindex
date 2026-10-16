// A spam airdrop can pack one block with more logs of a common event than a
// provider will return for a query without an address filter. A single block
// can't be narrowed any further, so the page has to be read again with the
// tracked addresses in the filter instead.
let port = 18550
let url = `http://127.0.0.1:${port->Int.toString}`

let addresses = RpcE2eChain.trackedAddresses(1_000)

let transfers: array<RpcE2eChain.transfer> = [{blockNumber: 100, value: 3, logIndex: 0}]

let mock = RpcE2eChain.serveDuringSuite(() =>
  MockRpcServer.start(~port, ~handler=body => {
    let request = body->JSON.parseOrThrow->JSON.Decode.object->Option.getOrThrow
    let method = request->Dict.getUnsafe("method")->JSON.Decode.string->Option.getOrThrow
    let params = request->Dict.getUnsafe("params")
    let isAddressFreeLogs =
      method == "eth_getLogs" &&
        params
        ->JSON.Decode.array
        ->Option.getOrThrow
        ->Array.getUnsafe(0)
        ->JSON.Decode.object
        ->Option.getOrThrow
        ->Dict.get("address")
        ->Option.isNone
    let reply = if isAddressFreeLogs {
      dict{
        "error": JSON.parseOrThrow(`{"code":-32005,"message":"query returned more than 10000 results"}`),
      }
    } else {
      dict{"result": RpcE2eChain.resultFor(~transfers, ~height=105, ~method, ~params)}
    }
    reply->Dict.set("jsonrpc", JSON.String("2.0"))
    reply->Dict.set("id", request->Dict.getUnsafe("id"))
    (200, JSON.stringify(JSON.Object(reply)))
  })
)

let _ = InternalTestIndexer.fromUserApi(
  ~configYaml=RpcE2eChain.configYaml(~name="rpc-address-free-fallback-e2e", ~url, ~addresses),
  ~schema=RpcE2eChain.schema,
  ~handlers=RpcE2eChain.handlers,
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer, type Transfer, TestHelpers } from "envio";

const { Addresses } = TestHelpers;

describe("Indexing many addresses over RPC through a spam block", () => {
  it("indexes the block the provider refused without an address filter", async (t) => {
    const indexer = createTestIndexer();

    await indexer.process({ chains: { 1337: { startBlock: 100, endBlock: 100 } } });

    const expected: Transfer = { id: "100-0", to: Addresses.mockAddresses[1], value: 3n };
    t.expect(await indexer.Transfer.get("100-0")).toEqual(expected);
  });
});
`,
)

Vitest.it("re-read the refused block with the address filter", t => {
  t.expect(mock()->RpcE2eChain.logFilters).toEqual([
    "0x64-0x64 addresses=0",
    "0x64-0x64 addresses=1000",
  ])
})
