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

indexer.onEvent({ contract: "Gravatar", event: "FactoryEvent" }, async ({ event, context }) => {
  if (context.isPreload) {
    return;
  }
  const bad = { createdAt: { _eq: "2020-01-01" as unknown as Date } };
  if (event.params.testCase === "rejects") {
    try {
      await context.Item.getWhere(bad);
      context.Probe.set({ id: "accepted" });
    } catch (error) {
      context.Probe.set({ id: (error as Error).message });
    }
    return;
  }
  // Both calls share an operation key, so they are batched together.
  const [good, rejected] = await Promise.allSettled([
    context.Item.getWhere({ createdAt: { _eq: new Date(1000) } }),
    context.Item.getWhere(bad),
  ]);
  context.Probe.set({
    id: \`\${good.status}:\${good.status === "fulfilled" ? good.value.length : 0}/\${rejected.status}\`,
  });
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
                testCase: "rejects",
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

  it("fails only the rejected call, not the ones batched with it", async (t) => {
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
                testCase: "isolates",
              },
            },
          ],
        },
      },
    });

    t.expect(result.changes[0]?.Probe).toEqual({ sets: [{ id: "fulfilled:1/rejected" }] });
  });
});
`,
)
