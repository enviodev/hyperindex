// What a transaction handler can do with its context, checked against an
// event handler doing the same: effects, cached or not, the preload pass
// before the run proper, entity reads and writes, and how a throw from the
// handler or from an effect surfaces at the process() call site.
let _ = InternalTestIndexer.fromUserApi(
  ~configYaml=`
name: on-transaction-handler-context
contracts:
  - name: Token
    events:
      - event: Transfer(address indexed from, address indexed to, uint256 value)
chains:
  - id: 1
    start_block: 0
    contracts:
      - name: Token
        address: "0x1111111111111111111111111111111111111111"
`,
  ~schema=`
type Probe {
  id: ID!
  kind: String!
  cached: String!
  effectRuns: Int!
  preload: Boolean!
  chainId: Int!
  realtime: Boolean!
}

type Tally {
  id: ID!
  kind: String!
  count: Int!
}
`,
  ~handlers=`
import { indexer, createEffect, S } from "envio";

const alice = "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const token = "0x1111111111111111111111111111111111111111";

const cachedEffect = createEffect(
  { name: "cachedEffect", input: { id: S.string }, output: S.string, rateLimit: false, cache: true },
  async ({ input }) => "cached-" + input.id,
);

// Counts its runs, so a row says how many passes called it.
let runs = 0;
const countingEffect = createEffect(
  { name: "countingEffect", input: S.string, output: S.number, rateLimit: false },
  async () => ++runs,
);

const throwingEffect = createEffect(
  { name: "throwingEffect", input: S.string, output: S.string, rateLimit: false },
  async () => {
    throw new Error("Error from effect");
  },
);

type Context = any;

// The same work from either kind of handler.
const probe = async (context: Context, kind: string, id: string, input: string) => {
  switch (input.slice(0, 10)) {
    case "0xdeadbeef":
      throw new Error("Error from " + kind + " handler");
    case "0xeffec7ed":
      await context.effect(throwingEffect, id);
      return;
  }
  const cached = await context.effect(cachedEffect, { id });
  const effectRuns = await context.effect(countingEffect, id);
  context.Probe.set({
    id,
    kind,
    cached,
    effectRuns,
    preload: context.isPreload,
    chainId: context.chain.id,
    realtime: context.chain.isRealtime,
  });
  const seen = await context.Probe.getWhere({ kind: { _eq: kind } });
  const tally = (await context.Tally.get(kind)) ?? { id: kind, kind, count: 0 };
  context.Tally.set({ ...tally, count: seen.length });
};

indexer.onTransaction(
  { name: "from-alice", where: () => ({ transaction: { from: [alice] } }), fields: { transaction: ["input"] } },
  async ({ transaction, block, context }) =>
    probe(context, "transaction", \`tx-\${block.number}-\${transaction.transactionIndex}\`, transaction.input),
);

indexer.onEvent(
  { contract: "Token", event: "Transfer", fields: { transaction: ["input"] } },
  async ({ event, context }) =>
    probe(context, "event", \`ev-\${event.block.number}-\${event.logIndex}\`, event.transaction.input),
);
`,
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

const alice = "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const bob = "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";

const transaction = (number: number, input: string) => ({
  transaction: { from: alice, to: bob, input },
  block: { number },
});
const transfer = (number: number, input: string) => ({
  contract: "Token" as const,
  event: "Transfer" as const,
  params: { from: alice, to: bob, value: 1n },
  transaction: { input },
  block: { number },
});

const byId = (a: { id: string }, b: { id: string }) => a.id.localeCompare(b.id);

describe("a transaction handler's context", () => {
  it("runs effects and reads and writes entities the way an event handler does", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({
      chains: {
        1: {
          startBlock: 0,
          endBlock: 10,
          simulate: [transaction(2, "0x"), transfer(3, "0x"), transaction(4, "0x"), transfer(5, "0x")],
        },
      },
    });
    const probes = (await indexer.Probe.getAll()).sort(byId);
    const events = probes.filter((probe) => probe.kind === "event");
    const transactions = probes.filter((probe) => probe.kind === "transaction");
    t.expect({
      transactions: transactions.map(({ id, cached, preload, chainId, realtime }) => ({ id, cached, preload, chainId, realtime })),
      // Once per handler: the run proper reuses what the preload pass got.
      totalEffectRuns: Math.max(...probes.map((probe) => probe.effectRuns)),
      tallies: (await indexer.Tally.getAll()).sort(byId),
    }).toEqual({
      transactions: [
        { id: "tx-2-0", cached: "cached-tx-2-0", preload: false, chainId: 1, realtime: false },
        { id: "tx-4-0", cached: "cached-tx-4-0", preload: false, chainId: 1, realtime: false },
      ],
      totalEffectRuns: events.length + transactions.length,
      tallies: [
        { id: "event", kind: "event", count: 2 },
        { id: "transaction", kind: "transaction", count: 2 },
      ],
    });
  });

  it("surfaces a throw from the handler at the process() call site", async (t) => {
    const indexer = createTestIndexer();
    await t
      .expect(
        indexer.process({
          chains: { 1: { startBlock: 0, endBlock: 10, simulate: [transaction(2, "0xdeadbeef")] } },
        }),
      )
      .rejects.toThrow("Error from transaction handler");
  });

  it("surfaces a throw from an effect at the process() call site", async (t) => {
    const indexer = createTestIndexer();
    await t
      .expect(
        indexer.process({
          chains: { 1: { startBlock: 0, endBlock: 10, simulate: [transaction(2, "0xeffec7ed")] } },
        }),
      )
      .rejects.toThrow("Error from effect");
  });
});
`,
)
