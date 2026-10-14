// An entity named `sidecar` next to a configured sidecar: entities sit on the
// handler context, the test indexer and its changes under their capitalized
// name, so the entity is `Sidecar` and never shadows `context.sidecar`.
let _ = InternalTestIndexer.fromUserApi(
  ~configYaml=`
name: test-indexer-sidecar-entity
sidecar:
  contract: src/sidecar/contract.ts
  entry: src/sidecar/index.ts
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
type sidecar {
  id: ID!
  callId: String!
}
`,
  ~sidecarContract=`
import { defineSidecar, S } from "envio";

export default defineSidecar({
  functions: {
    notify: { input: { text: S.string } },
  },
});
`,
  ~handlers=`
import { indexer } from "envio";

indexer.onEvent({ contract: "Gravatar", event: "NewGravatar" }, async ({ event, context }) => {
  const callId: string = context.sidecar.notify({ text: event.params.displayName });
  context.Sidecar.set({ id: event.params.owner, callId });

  if (event.params.displayName === "never") {
    // @ts-expect-error context.sidecar is the sidecar caller, not entity operations
    context.sidecar.set({ id: "x", callId: "y" });
  }
});
`,
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer, type Sidecar, TestHelpers } from "envio";

const [owner] = TestHelpers.Addresses.mockAddresses;

describe("an entity named sidecar", () => {
  it("is context.Sidecar, next to context.sidecar", async (t) => {
    const indexer = createTestIndexer();
    const result = await indexer.process({
      chains: {
        1: {
          simulate: [
            {
              contract: "Gravatar",
              event: "NewGravatar",
              params: { id: 7n, owner, displayName: "hi", imageUrl: "" },
              block: { number: 5, timestamp: 500 },
              logIndex: 3,
            },
          ],
        },
      },
    });
    const callId = indexer.sidecar.calls[0]?.id ?? "no call recorded";
    const row: Sidecar = { id: owner, callId };

    t.expect({
      changes: result.changes,
      calls: indexer.sidecar.calls.map(({ fn, input }) => ({ fn, input })),
      row: await indexer.Sidecar.get(owner),
    }).toEqual({
      changes: [
        {
          block: 5,
          chainId: 1,
          eventsProcessed: 1,
          sidecar: { calls: [{ id: callId, fn: "notify", input: { text: "hi" } }] },
          Sidecar: { sets: [row] },
        },
      ],
      calls: [{ fn: "notify", input: { text: "hi" } }],
      row,
    });
  });
});
`,
)
