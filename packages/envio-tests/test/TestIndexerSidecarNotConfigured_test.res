// Without `sidecar:` in config.yaml the types reject `context.sidecar.<fn>`, but
// a JavaScript handler can still reach it: the call is dropped with a warning
// and still gets an id, so nothing throws into the handler.
let _ = InternalTestIndexer.fromUserApi(
  ~configYaml=`
name: test-indexer-sidecar-not-configured
chains:
  - id: 1
    start_block: 1
    contracts:
      - name: Gravatar
        address: "0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3"
        events:
          - event: "NewGravatar(uint256 id, address owner, string displayName, string imageUrl)"
`,
  ~schema=`
type Probe {
  id: ID!
}
`,
  ~handlers=`
import { indexer } from "envio";

indexer.onEvent({ contract: "Gravatar", event: "NewGravatar" }, async ({ context }) => {
  // @ts-expect-error no sidecar is configured
  const id: string = context.sidecar.notify({ text: "hi" });
  context.Probe.set({ id });
});
`,
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer, TestHelpers } from "envio";

const [owner] = TestHelpers.Addresses.mockAddresses;

describe("context.sidecar without a sidecar configured", () => {
  it("drops the call and still returns its id", async (t) => {
    const indexer = createTestIndexer();
    const result = await indexer.process({
      chains: {
        1: {
          startBlock: 1,
          endBlock: 100,
          simulate: [
            {
              contract: "Gravatar",
              event: "NewGravatar",
              params: { id: 1n, owner, displayName: "hi", imageUrl: "" },
              block: { number: 5 },
              logIndex: 3,
            },
          ],
        },
      },
    });

    // @ts-expect-error no sidecar is configured
    const calls: unknown = indexer.sidecar.calls;

    t.expect({ changes: result.changes, calls }).toEqual({
      changes: [{ block: 5, chainId: 1, eventsProcessed: 1, Probe: { sets: [{ id: "1:5:3r1:0" }] } }],
      calls: [],
    });
  });
});
`,
)
