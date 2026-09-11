// An entity has to leave the index its old value matched and join the one its
// new value matches, and leave every index when it is deleted.
let _ = InternalTestIndexer.fromUserApi(
  ~configYaml=`
name: get-where-index-upkeep
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
  owner: String! @index
  rank: Int! @index
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
  const byOwner = async (owner: string) =>
    (await context.Item.getWhere({ owner: { _eq: owner } })).map((i) => i.id).sort().join(",");
  const aboveRank = async (rank: number) =>
    (await context.Item.getWhere({ rank: { _gt: rank } })).map((i) => i.id).sort().join(",");

  // Register both equality indexes and a range index before anything matches.
  await byOwner("alice");
  await byOwner("bob");
  await aboveRank(10);

  context.Item.set({ id: "x", owner: "alice", rank: 5 });
  const first = \`\${await byOwner("alice")}/\${await byOwner("bob")}/\${await aboveRank(10)}\`;

  context.Item.set({ id: "x", owner: "bob", rank: 50 });
  const moved = \`\${await byOwner("alice")}/\${await byOwner("bob")}/\${await aboveRank(10)}\`;

  context.Item.deleteUnsafe("x");
  const gone = \`\${await byOwner("alice")}/\${await byOwner("bob")}/\${await aboveRank(10)}\`;

  context.Probe.set({ id: \`\${first} | \${moved} | \${gone}\` });
});
`,
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("in-memory index upkeep", () => {
  it("moves an entity between indexes when its indexed values change", async (t) => {
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
                testCase: "indexUpkeep",
              },
            },
          ],
        },
      },
    });

    t.expect(result.changes[0]?.Probe).toEqual({
      sets: [{ id: "x// | /x/x | //" }],
    });
  });
});
`,
)
