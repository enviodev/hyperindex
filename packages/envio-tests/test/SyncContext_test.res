// Internal sync context surface (getSync / getWhereSync / getInBlockSync /
// effectSync / runSync) used by the subgraph runtime. Not part of the public
// API, so the handlers reach it through a cast.
let _ = InternalTestIndexer.fromUserApi(
  ~configYaml=`
name: sync-context
chains:
  - id: 1
    start_block: 0
    contracts:
      - name: Token
        address: "0x1111111111111111111111111111111111111111"
        events:
          - event: Transfer(address indexed from, address indexed to, uint256 value)
          - event: Approval(address indexed owner, address indexed spender, uint256 value)
          - event: Mint(address indexed to, uint256 value)
          - event: Burn(address indexed from, uint256 value)
          - event: Freeze(address indexed who)
          - event: Thaw(address indexed who)
          - event: Pair(address indexed a, address indexed b)
          - event: Quote(address indexed who)
`,
  ~schema=`
type Account {
  id: ID!
  balance: BigInt!
}

type Note {
  id: ID!
  owner: String! @index
  text: String!
}
`,
  ~handlers=`
import { indexer, createEffect, S } from "envio";

const g = globalThis as any;
g.rounds = [];
g.effectCalls = 0;
g.freezeRound = 0;
g.thawRounds = [];
g.pairRounds = [];
g.quoteRounds = [];
g.quoteInputs = [];

const describeBalance = createEffect(
  {
    name: "describeBalance",
    input: S.bigint,
    output: S.string,
    rateLimit: false,
    cache: false,
  },
  async ({ input }) => {
    g.effectCalls++;
    return "balance:" + input.toString();
  },
);

const quoteBalance = createEffect(
  {
    name: "quoteBalance",
    input: S.bigint,
    output: S.string,
    rateLimit: false,
    cache: false,
  },
  async ({ input }) => {
    g.quoteInputs.push(input);
    return "quote:" + input.toString();
  },
);

// Two reads that don't depend on each other.
indexer.onEvent({ contract: "Token", event: "Pair" }, async ({ event, context }) => {
  const ctx = context as any;
  let round = 0;
  await ctx.runSync(() => {
    round++;
    const a = ctx.Account.getSync(event.params.a);
    const b = ctx.Account.getSync(event.params.b);
    ctx.Account.set({ id: event.params.a, balance: (a?.balance ?? 0n) + (b?.balance ?? 0n) + 1n });
  });
  g.pairRounds.push([context.isPreload, round]);
});

// An effect asked with what a read returned.
indexer.onEvent({ contract: "Token", event: "Quote" }, async ({ event, context }) => {
  const ctx = context as any;
  let round = 0;
  await ctx.runSync(() => {
    round++;
    const account = ctx.Account.getSync(event.params.who);
    const quote = ctx.effectSync(quoteBalance, account?.balance ?? 0n);
    ctx.Note.set({ id: event.params.who + "-quote", owner: event.params.who, text: quote });
  });
  g.quoteRounds.push([context.isPreload, round]);
});

indexer.onEvent({ contract: "Token", event: "Transfer" }, async ({ event, context }) => {
  const ctx = context as any;
  let round = 0;
  await ctx.runSync(() => {
    round++;
    const existing = ctx.Account.getSync(event.params.to);
    ctx.Account.set({
      id: event.params.to,
      balance: (existing?.balance ?? 0n) + event.params.value,
    });
  });
  g.rounds.push([context.isPreload, round]);
});

// Reads its own write back through the checkpoint-scoped read: a hit only
// counts when the change was made in the block this handler runs in.
indexer.onEvent({ contract: "Token", event: "Mint" }, async ({ event, context }) => {
  const ctx = context as any;
  await ctx.runSync(() => {
    const before = ctx.Account.getInBlockSync(event.params.to);
    ctx.Account.set({
      id: event.params.to,
      balance: (before?.balance ?? 0n) + event.params.value,
    });
    ctx.Note.set({
      id: event.params.to + "-" + String(event.block.number) + "-" + String(event.logIndex),
      owner: event.params.to,
      text: before === null || before === undefined ? "fresh" : "in-block",
    });
  });
});

// effectSync with cache: false — resolved once and reused across the replay
// rounds and the preload -> execute transition.
indexer.onEvent({ contract: "Token", event: "Burn" }, async ({ event, context }) => {
  const ctx = context as any;
  await ctx.runSync(() => {
    const described = ctx.effectSync(describeBalance, event.params.value);
    const notes = ctx.Note.getWhereSync({ owner: { _eq: event.params.from } });
    ctx.Note.set({
      id: event.params.from + "-burn",
      owner: event.params.from,
      text: described + "/" + String(notes.length),
    });
  });
});

// A swallowed suspend must not let the handler carry on: the next context
// interaction — trap access or an op closure grabbed before the abort —
// re-throws it.
indexer.onEvent({ contract: "Token", event: "Approval" }, async ({ context }) => {
  const ctx = context as any;
  if (context.isPreload) {
    return;
  }
  ctx.Account.getSync("approval-never-loaded");
  ctx.Account.set({ id: "approval-should-not-land", balance: 1n });
});

indexer.onEvent({ contract: "Token", event: "Thaw" }, async ({ context }) => {
  const ctx = context as any;
  if (context.isPreload) {
    return;
  }
  await ctx.runSync(() => {
    try {
      g.thawRounds.push(ctx.Account.getSync("thaw") === undefined ? "absent" : "present");
    } catch (e) {
      g.thawRounds.push("suspended");
    }
  });
});

indexer.onEvent({ contract: "Token", event: "Freeze" }, async ({ context }) => {
  const ctx = context as any;
  await ctx.runSync(() => {
    // A fresh key every round never converges. The counter is global so the
    // execute pass keeps diverging past what preload already loaded.
    g.freezeRound++;
    ctx.Account.getSync("freeze-" + String(g.freezeRound));
  });
});
`,
  ~test=`
import { afterAll, beforeAll, describe, it, expect } from "vitest";
import { createTestIndexer, TestHelpers } from "envio";

// The sync surface is the subgraph runtime's, so it exists in subgraph mode.
// Env ships no declarations: a specifier that isn't a literal skips its types.
const envModule: string = "envio/src/Env.res.mjs";
const { subgraphMode } = await import(envModule);
beforeAll(() => {
  subgraphMode.contents = true;
});
afterAll(() => {
  subgraphMode.contents = false;
});

const { Addresses } = TestHelpers;
const g = globalThis as any;
const to = Addresses.defaultAddress;
const from = Addresses.mockAddresses[1];

describe("sync context", () => {
  it("suspends on a miss, replays, then hits in memory", async (t) => {
    const indexer = createTestIndexer();
    g.rounds = [];

    await indexer.process({
      chains: {
        1: { simulate: [{ contract: "Token", event: "Transfer", params: { from, to, value: 5n } }] },
      },
    });

    t.expect(await indexer.Account.getOrThrow(to)).toEqual({ id: to, balance: 5n });
    // Preload misses and replays; execute finds the value already loaded.
    t.expect(g.rounds).toEqual([[true, 2], [false, 1]]);
  });

  // Preload answers a miss as absent and runs on, so the second read joins
  // the first one's batch instead of costing a round of its own.
  it("batches independent preload reads into one round", async (t) => {
    const indexer = createTestIndexer();
    g.pairRounds = [];

    await indexer.process({
      chains: {
        1: { simulate: [{ contract: "Token", event: "Pair", params: { a: to, b: from } }] },
      },
    });

    t.expect(await indexer.Account.getOrThrow(to)).toEqual({ id: to, balance: 1n });
    t.expect(g.pairRounds).toEqual([[true, 2], [false, 1]]);
  });

  // An effect is never asked with a value computed from a speculated absence.
  it("asks an effect only with what the store holds", async (t) => {
    const indexer = createTestIndexer();
    g.quoteRounds = [];
    g.quoteInputs = [];

    await indexer.process({
      chains: {
        1: { simulate: [{ contract: "Token", event: "Transfer", params: { from, to, value: 5n } }] },
      },
    });
    await indexer.process({
      chains: {
        1: { simulate: [{ contract: "Token", event: "Quote", params: { who: to } }] },
      },
    });

    t.expect(await indexer.Note.getOrThrow(to + "-quote")).toEqual({
      id: to + "-quote",
      owner: to,
      text: "quote:5",
    });
    t.expect(g.quoteInputs).toEqual([5n]);
    t.expect(g.quoteRounds).toEqual([[true, 3], [false, 1]]);
  });

  it("accumulates across batches", async (t) => {
    const indexer = createTestIndexer();

    await indexer.process({
      chains: {
        1: { simulate: [{ contract: "Token", event: "Transfer", params: { from, to, value: 3n } }] },
      },
    });
    await indexer.process({
      chains: {
        1: { simulate: [{ contract: "Token", event: "Transfer", params: { from, to, value: 4n } }] },
      },
    });

    t.expect(await indexer.Account.getOrThrow(to)).toEqual({ id: to, balance: 7n });
  });

  it("scopes getInBlockSync to the current block", async (t) => {
    const indexer = createTestIndexer();

    await indexer.process({
      chains: {
        1: {
          simulate: [
            { contract: "Token", event: "Mint", params: { to, value: 1n }, block: { number: 10 } },
            { contract: "Token", event: "Mint", params: { to, value: 1n }, block: { number: 10 } },
            { contract: "Token", event: "Mint", params: { to, value: 1n }, block: { number: 11 } },
          ],
        },
      },
    });

    const notes = await indexer.Note.getWhere({ owner: { _eq: to } });
    t.expect(notes.map((n) => [n.id, n.text]).sort()).toEqual([
      [to + "-10-0", "fresh"],
      [to + "-10-1", "in-block"],
      // Written in an earlier block of the same batch — not a hit.
      [to + "-11-2", "fresh"],
    ]);
  });

  it("resolves effectSync once with cache: false", async (t) => {
    const indexer = createTestIndexer();
    g.effectCalls = 0;

    await indexer.process({
      chains: {
        1: { simulate: [{ contract: "Token", event: "Burn", params: { from, value: 42n } }] },
      },
    });

    t.expect(await indexer.Note.getOrThrow(from + "-burn")).toEqual({
      id: from + "-burn",
      owner: from,
      text: "balance:42/0",
    });
    t.expect(g.effectCalls).toBe(1);
  });

  // A sync read has a round to suspend and replay only inside runSync.
  it("refuses a sync read outside runSync", async (t) => {
    const indexer = createTestIndexer();

    await expect(
      indexer.process({
        chains: {
          1: {
            simulate: [
              { contract: "Token", event: "Approval", params: { owner: from, spender: to, value: 1n } },
            ],
          },
        },
      }),
    ).rejects.toThrow("context.Account.getSync is only available inside context.runSync.");

    t.expect(await indexer.Account.get("approval-should-not-land")).toBe(undefined);
  });

  // A round that returns without the reads it asked for didn't finish: it is
  // replayed, not taken as the handler's result.
  it("replays a round that swallowed its suspend", async (t) => {
    const indexer = createTestIndexer();
    g.thawRounds = [];

    await indexer.process({
      chains: {
        1: { simulate: [{ contract: "Token", event: "Thaw", params: { who: from } }] },
      },
    });

    t.expect(g.thawRounds).toEqual(["suspended", "absent"]);
  });

  it("caps replay rounds", async (t) => {
    const indexer = createTestIndexer();

    await expect(
      indexer.process({
        chains: {
          1: { simulate: [{ contract: "Token", event: "Freeze", params: { who: from } }] },
        },
      }),
    ).rejects.toThrow(/gave up after 10000 rounds/);
  });
});
`,
)
