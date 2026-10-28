// A Json document is the same document whatever order its keys were set in, so
// a getWhere names it in any order. The in-memory index buckets entities by the
// document's text, which spells the keys in the order they were set.
let _ = InternalTestIndexer.fromUserApi(
  ~configYaml=`
name: json-get-where
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
type Doc {
  id: ID!
  payload: Json!
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
  switch (event.params.testCase) {
    case "eqInAnotherOrder": {
      await context.Doc.getWhere({ payload: { _eq: { b: 1, a: 2 } } });
      context.Doc.set({ id: "1", payload: { a: 2, b: 1 } });
      const found = await context.Doc.getWhere({ payload: { _eq: { b: 1, a: 2 } } });
      context.Probe.set({ id: "eq:" + found.map((doc) => doc.id).join(",") });
      return;
    }
    case "inInAnotherOrder": {
      await context.Doc.getWhere({ payload: { _in: [{ b: 1, a: 2 }] } });
      context.Doc.set({ id: "1", payload: { a: 2, b: 1 } });
      const found = await context.Doc.getWhere({ payload: { _in: [{ b: 1, a: 2 }] } });
      context.Probe.set({ id: "in:" + found.map((doc) => doc.id).join(",") });
      return;
    }
  }
});
`,
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

const run = (testCase: string) =>
  createTestIndexer().process({
    chains: {
      1: {
        startBlock: 1,
        endBlock: 100,
        simulate: [
          {
            contract: "Gravatar",
            event: "FactoryEvent",
            params: { contract: "0x1234567890123456789012345678901234567890", testCase },
          },
        ],
      },
    },
  });

describe("getWhere on a Json field", () => {
  it("finds a document set with its keys in another order", async (t) => {
    const [eq, inList] = [await run("eqInAnotherOrder"), await run("inInAnotherOrder")];

    t.expect([eq.changes[0]?.Probe, inList.changes[0]?.Probe]).toEqual([
      { sets: [{ id: "eq:1" }] },
      { sets: [{ id: "in:1" }] },
    ]);
  });
});
`,
)
