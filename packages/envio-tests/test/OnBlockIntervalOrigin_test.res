// A block handler without its own start counts its interval from the chain's
// start block, whether its blocks are generated or fetched for their fields.
let _ = InternalTestIndexer.fromUserApi(
  ~configYaml=`
name: on-block-interval-origin
chains:
  - id: 1
    start_block: 3
`,
  ~schema=`
type Run {
  id: ID!
}
`,
  ~handlers=`
import { indexer } from "envio";

indexer.onBlock(
  { name: "fetched", where: () => ({ block: { number: { _every: 5 } } }), fields: { block: ["timestamp"] } },
  async ({ block, context }) => {
    context.Run.set({ id: \`fetched:\${block.number}\` });
  },
);

indexer.onBlock(
  { name: "generated", where: () => ({ block: { number: { _every: 5 } } }) },
  async ({ block, context }) => {
    context.Run.set({ id: \`generated:\${block.number}\` });
  },
);
`,
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("A block handler's interval origin", () => {
  it("is the chain's start block", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({
      chains: {
        1: {
          startBlock: 3,
          endBlock: 13,
          simulate: [3, 8, 13].map((number) => ({ block: { number, timestamp: number } })),
        },
      },
    });
    t.expect((await indexer.Run.getAll()).map((run) => run.id).sort()).toEqual([
      "fetched:13",
      "fetched:3",
      "fetched:8",
      "generated:13",
      "generated:3",
      "generated:8",
    ]);
  });
});
`,
)
