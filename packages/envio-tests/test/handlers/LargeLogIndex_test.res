// Some RPC providers number synthetic logs from the top of the 32-bit range,
// such as 0xffffffe2. A log index above 2^31 - 1 reaches the handler unchanged.
//
// It is served over RPC because a fetched log is kept in the event store's
// columns, while a simulated one stays the JS object it was given.
let port = 18553
let url = `http://127.0.0.1:${port->Int.toString}`

let largeLogIndex = 4294967266.->(Utils.magic: float => int)

let transfers: array<RpcE2eChain.transfer> = [{blockNumber: 100, value: 3, logIndex: largeLogIndex}]

let _ = RpcE2eChain.serveDuringSuite(() =>
  MockRpcServer.makeWithParams(~port, ~getResult=(~method, ~params) =>
    RpcE2eChain.resultFor(~transfers, ~height=105, ~method, ~params)
  )
)

let _ = InternalTestIndexer.fromUserApi(
  ~configYaml=RpcE2eChain.configYaml(~name="large-log-index", ~url),
  ~schema=RpcE2eChain.schema,
  ~handlers=RpcE2eChain.handlers,
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("a log whose index is above 2^31 - 1", () => {
  it("reaches the handler with its log index unchanged", async (t) => {
    const indexer = createTestIndexer();

    await indexer.process({ chains: { 1337: { startBlock: 100, endBlock: 100 } } });

    t.expect((await indexer.Transfer.getAll()).map((transfer) => transfer.id)).toEqual([
      "100-4294967266",
    ]);
  });
});
`,
)
