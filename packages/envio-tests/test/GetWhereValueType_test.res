// A filter value whose runtime type doesn't match the column reached the
// comparison and crashed there. Handlers are typed, but a JS handler carries no
// types, so the value arrives unchecked — the cast below stands in for that.
let _ = InternalTestIndexer.fromUserApi(
  ~configYaml=`
name: get-where-value-type
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
  try {
    await context.Item.getWhere({
      createdAt: { _eq: "2020-01-01" as unknown as Date },
    });
    context.Probe.set({ id: "accepted" });
  } catch (error) {
    context.Probe.set({ id: (error as Error).message });
  }
});
`,
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("getWhere filter value type", () => {
  it("rejects a value that isn't a Date on a Timestamp column", async (t) => {
    const indexer = createTestIndexer();
    indexer.Item.set({ id: "item", createdAt: new Date(1000) });

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
                testCase: "dateValueType",
              },
            },
          ],
        },
      },
    });

    t.expect(result.changes[0]?.Probe).toEqual({
      sets: [
        {
          id: \`Invalid value passed to context.Item.getWhere({ createdAt: { _eq: ... } }). The field "createdAt" expects a Date.\`,
        },
      ],
    });
  });
});
`,
)
