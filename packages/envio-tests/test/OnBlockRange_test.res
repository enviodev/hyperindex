open Vitest

// Each block handler runs on the blocks its interval, start and end pick, after
// the events of that block, and block handlers of one block run in the order
// they were registered.
let scenario = Scenario.make(
  ~configYaml=`
name: on-block-range
contracts:
  - name: Token
    events:
      - event: Transfer()
chains:
  - id: 1
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 0
    contracts:
      - name: Token
        address: "0x0000000000000000000000000000000000000001"
`,
  ~schema=`
type Run {
  id: ID!
  order: String!
}
`,
  ~handlers=`
import { indexer } from "envio";

type RunStore = {
  get: (id: string) => Promise<{ order: string } | undefined>;
  set: (run: { id: string; order: string }) => void;
};

const record = async (context: { Run: RunStore }, label: string) => {
  const run = await context.Run.get("run");
  context.Run.set({ id: "run", order: run ? run.order + " " + label : label });
};

indexer.onEvent({ contract: "Token", event: "Transfer" }, async ({ event, context }) => {
  await record(context, \`Transfer@\${event.block.number}\`);
});

const onBlock = (name: string, number: { _every: number } | { _gte: number } | { _lte: number }) =>
  indexer.onBlock({ name, where: () => ({ block: { number } }) }, async ({ block, context }) => {
    await record(context, \`\${name}@\${block.number}\`);
  });

onBlock("every2", { _every: 2 });
onBlock("every3", { _every: 3 });
onBlock("from5", { _gte: 5 });
onBlock("until8", { _lte: 8 });
`,
)

type run = {id: string, order: string}

describe("Block handlers", () => {
  scenario->Scenario.it(
    "run on the blocks their interval, start and end pick, after the block's events",
    ~sources=[{chain: 1}],
    async (~t, ~indexer, ~source) => {
      let mock = source(1)
      mock.resolveGetHeightOrThrow(100)
      await mock.expectItemsQueries([
        {
          reply: Respond({
            items: [{event: "Token.Transfer", blockNumber: 5, logIndex: 0}],
            latestFetchedBlockNumber: 12,
          }),
        },
      ])
      await indexer.getBatchWritePromise()
      t.expect((await indexer.query("Run"): array<run>)).toEqual([
        {
          id: "run",
          order: [
            "every2@0 every3@0 until8@0",
            "until8@1",
            "every2@2 until8@2",
            "every3@3 until8@3",
            "every2@4 until8@4",
            "Transfer@5 from5@5 until8@5",
            "every2@6 every3@6 from5@6 until8@6",
            "from5@7 until8@7",
            "every2@8 from5@8 until8@8",
            "every3@9 from5@9",
            "every2@10 from5@10",
            "from5@11",
            "every2@12 every3@12 from5@12",
          ]->Array.join(" "),
        },
      ])
    },
  )
})
