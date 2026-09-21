// The other kind of bad RPC answer, and the one that must not be retried: the
// provider serves a page but leaves out a field the user selected. Retrying the
// same provider can only produce the same gap, so the run has to stop rather
// than index events whose selected fields were never populated.
//
// The source pins the distinction — a missing selected field is an error, a
// missing unselected one is a backoff — but only as a thrown variant. What no
// test covered is what reaches a user: whether the run fails at all, whether
// anything is written on the way down, and what the caller can learn from it.
let port = 18547
let url = `http://127.0.0.1:${port->Int.toString}`

let transfers: array<RpcE2eChain.transfer> = [{blockNumber: 100, value: 3, logIndex: 0}]

let server = ref(None)
let mock = () =>
  server.contents->Option.getOrThrow(~message="the mock RPC server was never started")

Vitest.Async.beforeAll(async () => {
  let started = await MockRpcServer.makeWithParams(~port, ~getResult=(~method, ~params) =>
    RpcE2eChain.resultFor(~transfers, ~height=105, ~method, ~params)
  )
  server := Some(started)
})

Vitest.Async.afterAll(async () => {
  switch server.contents {
  | Some(started) => await started.closeAsync()
  | None => ()
  }
})

let _ = InternalTestIndexer.fromUserApi(
  ~configYaml=RpcE2eChain.configYaml(
    ~name="rpc-indexer-field-selection-e2e",
    ~url,
    // This chain's blocks carry number, timestamp, hash and parentHash only, so
    // selecting gasUsed asks for a field the provider never returns.
    ~fieldSelection="\nfield_selection:\n  block_fields:\n    - \"gasUsed\"",
  ),
  ~schema=RpcE2eChain.schema,
  ~handlers=RpcE2eChain.handlers,
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("Indexing over an RPC that drops a selected field", () => {
  it("fails the run rather than writing events missing the field", async (t) => {
    const indexer = createTestIndexer();

    let outcome = "resolved";
    try {
      await indexer.process({ chains: { 1337: { startBlock: 100, endBlock: 100 } } });
    } catch (error) {
      // The reason is logged — "the RPC response is missing the selected block
      // field: gasUsed" — but the rejection carries no payload, so a caller
      // testing their own indexer can only see that the run failed, not why.
      // Tightening that should turn this into an assertion on the message.
      outcome = error === null ? "rejected without a reason" : String(error);
    }

    t.expect([outcome, await indexer.Transfer.get("100-0")]).toEqual([
      "rejected without a reason",
      undefined,
    ]);
  });
});
`,
)

// A source that gave up before asking is indistinguishable from one that was
// never reached, so pin that the page really was fetched and then refused.
Vitest.it("refused the page after reading it", t => {
  t.expect(mock()->RpcE2eChain.logRanges).toEqual(["0x64-0x64"])
})
