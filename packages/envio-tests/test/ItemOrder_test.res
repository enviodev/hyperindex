open Vitest

// Handlers see a chain's items in processing order whatever order a source
// returns them in: by block, a block's events before its block handlers, then
// by log index, and one log routed to two registrations in registration order.
// A log the source repeats runs once.
let scenario = Scenario.make(
  ~configYaml=`
name: item-order
contracts:
  - name: Token
    events:
      - event: Transfer()
  - name: Vault
    events:
      - event: Transfer()
chains:
  - id: 1
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 5
    contracts:
      - name: Token
        address: "0x0000000000000000000000000000000000000001"
      - name: Vault
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
  await record(context, \`Token@\${event.block.number}:\${event.logIndex}\`);
});

indexer.onEvent({ contract: "Vault", event: "Transfer" }, async ({ event, context }) => {
  await record(context, \`Vault@\${event.block.number}:\${event.logIndex}\`);
});

indexer.onBlock(
  { name: "tick", where: () => ({ block: { number: { _every: 5 } } }) },
  async ({ block, context }) => {
    await record(context, \`tick@\${block.number}\`);
  },
);
`,
)

type run = {id: string, order: string}

describe("Item order", () => {
  scenario->Scenario.it(
    "follows block, events before block handlers, log index and registration, and runs a repeated log once",
    ~sources=[{chain: 1}],
    async (~t, ~indexer, ~source) => {
      let mock = source(1)
      mock.resolveGetHeightOrThrow(100)
      await mock.expectItemsQueries([
        {
          reply: Respond({
            items: [
              {event: "Token.Transfer", blockNumber: 6, logIndex: 0},
              {event: "Vault.Transfer", blockNumber: 5, logIndex: 2},
              {event: "Token.Transfer", blockNumber: 5, logIndex: 2},
              {event: "Token.Transfer", blockNumber: 5, logIndex: 1},
              {event: "Token.Transfer", blockNumber: 6, logIndex: 0},
            ],
            latestFetchedBlockNumber: 10,
          }),
        },
      ])
      await indexer.getBatchWritePromise()
      t.expect((await indexer.query("Run"): array<run>)).toEqual([
        {
          id: "run",
          order: "Token@5:1 Token@5:2 Vault@5:2 tick@5 Token@6:0 tick@10",
        },
      ])
    },
  )
})
