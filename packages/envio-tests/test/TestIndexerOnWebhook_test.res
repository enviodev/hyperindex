// `indexer.onWebhook`: its body is typed from the contract's webhook (or the
// built-in's call), and registering it leaves the test indexer working.
let _ = InternalTestIndexer.fromUserApi(
  ~configYaml=`
name: test-indexer-on-webhook
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
type Priced {
  id: ID!
  usd: Int!
}
`,
  ~sidecarContract=`
import { defineSidecar, S } from "envio";

export default defineSidecar({
  functions: { priceSwap: { input: { swapId: S.string } } },
  webhooks: { swapPriced: { body: { swapId: S.string, usd: S.int32 } } },
});
`,
  ~handlers=`
import { indexer } from "envio";

indexer.onWebhook({ name: "swapPriced" }, async ({ webhook, context }) => {
  const usd: number = webhook.body.usd;
  const block: number = webhook.block.number;
  context.Priced.set({ id: webhook.body.swapId, usd: usd + block * 0 });
  if (webhook.id === "never") {
    // @ts-expect-error not a field of the contract's body
    void webhook.body.price;
  }
});

indexer.onWebhook({ name: "sidecar.ack" }, async ({ webhook }) => {
  const callId: string = webhook.body.callId;
  if (webhook.body.fn === "priceSwap") {
    const swapId: string = webhook.body.input.swapId;
    void swapId;
  }
  void callId;
});

indexer.onWebhook({ name: "sidecar.dropped" }, async ({ webhook }) => {
  const reason: string = webhook.body.reason;
  void reason;
});

indexer.onWebhook({ name: "outsideTheContract" }, async ({ webhook }) => {
  const body: unknown = webhook.body;
  void body;
});

indexer.onEvent({ contract: "Gravatar", event: "NewGravatar" }, async ({ event, context }) => {
  context.Priced.set({ id: event.params.displayName, usd: 0 });
});
`,
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer, indexer as userIndexer, TestHelpers } from "envio";

const [owner] = TestHelpers.Addresses.mockAddresses;

describe("indexer.onWebhook", () => {
  it("is on the indexer and leaves the test indexer's processing as it was", async (t) => {
    const indexer = createTestIndexer();
    const result = await indexer.process({
      chains: {
        1: {
          simulate: [
            {
              contract: "Gravatar" as const,
              event: "NewGravatar" as const,
              params: { id: 1n, owner, displayName: "a", imageUrl: "" },
              block: { number: 5 },
            },
          ],
        },
      },
    });

    t.expect([typeof userIndexer.onWebhook, "onWebhook" in userIndexer, result.changes.map((change) => change.Priced)]).toEqual([
      "function",
      true,
      [{ sets: [{ id: "a", usd: 0 }] }],
    ]);
  });
});
`,
)
