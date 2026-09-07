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
g.caught = [];
g.freezeRound = 0;

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
  const set = ctx.Account.set;
  try {
    ctx.Account.getSync("approval-never-loaded");
  } catch (e) {
    g.caught.push("suspend");
  }
  set({ id: "approval-should-not-land", balance: 1n });
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
import { describe, it, expect } from "vitest";
import { createTestIndexer, TestHelpers } from "envio";

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

  it("aborts the context after a swallowed suspend", async (t) => {
    const indexer = createTestIndexer();
    g.caught = [];

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
    ).rejects.toThrow();

    t.expect(g.caught).toEqual(["suspend"]);
    t.expect(await indexer.Account.get("approval-should-not-land")).toBe(undefined);
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
