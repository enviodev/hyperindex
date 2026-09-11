// Two getWhere calls whose values differ by less than a second shared one
// in-memory index, because the filter cache key stringified a Date through
// Date.prototype.toString (second resolution). The second query answered with
// the first query's rows.
let _ = InternalTestIndexer.fromUserApi(
  ~configYaml=`
name: get-where-key
chains:
  - id: 1
    start_block: 1
    contracts:
      - name: Gravatar
        address: "0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3"
        events:
          - event: "FactoryEvent(address indexed contract, string testCase)"
`,
  ~schema=`
type Item {
  id: ID!
  createdAt: Timestamp! @index
}

type Probe {
  id: ID!
}
`,
  ~handlers=`
import { indexer } from "envio";

indexer.onEvent({ contract: "Gravatar", event: "FactoryEvent" }, async ({ context }) => {
  if (context.isPreload) {
    return;
  }
  const ids = async (createdAt: Date) =>
    (await context.Item.getWhere({ createdAt: { _eq: createdAt } }))
      .map((item) => item.id)
      .sort()
      .join("|");

  const early = await ids(new Date(1000));
  const late = await ids(new Date(1500));
  context.Probe.set({ id: \`early=\${early};late=\${late}\` });
});
`,
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("getWhere filter cache key", () => {
  it("keeps values within the same second apart", async (t) => {
    const indexer = createTestIndexer();
    indexer.Item.set({ id: "item-early", createdAt: new Date(1000) });
    indexer.Item.set({ id: "item-late", createdAt: new Date(1500) });

    const result = await indexer.process({
      chains: {
        1: {
          startBlock: 1,
          endBlock: 100,
          simulate: [
            {
              contract: "Gravatar",
              event: "FactoryEvent",
              params: {
                contract: "0x1234567890123456789012345678901234567890",
                testCase: "dateKey",
              },
            },
          ],
        },
      },
    });

    t.expect(result.changes[0]?.Probe).toEqual({
      sets: [{ id: "early=item-early;late=item-late" }],
    });
  });
});
`,
)
