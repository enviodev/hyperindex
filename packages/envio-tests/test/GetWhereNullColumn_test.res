// A JS handler can write `null` for a nullable column it doesn't set. SQL
// compares NULL to nothing, so an in-memory range filter must skip it too
// rather than coerce it to 0.
let _ = InternalTestIndexer.fromUserApi(
  ~configYaml=`
name: get-where-null-column
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
  rank: Int @index
  label: String @index
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
  const ids = async (filter: Parameters<typeof context.Item.getWhere>[0]) =>
    (await context.Item.getWhere(filter)).map((i) => i.id).sort().join(",");

  context.Item.set({ id: "null", rank: null as unknown as undefined, label: null as unknown as undefined });
  context.Item.set({ id: "undefined", rank: undefined, label: undefined });
  context.Item.set({ id: "set", rank: 5, label: "b" });

  context.Probe.set({
    id: [
      await ids({ rank: { _lt: 10 } }),
      await ids({ rank: { _lte: 10 } }),
      await ids({ rank: { _gt: -1 } }),
      await ids({ rank: { _gte: -1 } }),
      await ids({ label: { _lt: "c" } }),
      await ids({ label: { _gt: "a" } }),
    ].join("|"),
  });
});
`,
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("getWhere on a null column", () => {
  it("matches a null column with no range operator, the way SQL does", async (t) => {
    const indexer = createTestIndexer();

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
                testCase: "nullColumn",
              },
            },
          ],
        },
      },
    });

    t.expect(result.changes[0]?.Probe).toEqual({
      sets: [{ id: "set|set|set|set|set|set" }],
    });
  });
});
`,
)
