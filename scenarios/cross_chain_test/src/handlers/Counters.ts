import { S, createEffect, indexer } from "envio";

// No `crossChain` option: the config's `disable_default_cross_chain: true`
// makes it per-chain, so `context.chain.id` is readable.
export const chainLabel = createEffect(
  {
    name: "chainLabel",
    input: S.string,
    output: S.string,
    rateLimit: false,
  },
  async ({ input, context }) => `${input}@${context.chain.id}`,
);

// Explicitly opted back into a single cache shared by every chain, so
// `context.chain` is unavailable here.
export const shared = createEffect(
  {
    name: "shared",
    input: S.string,
    output: S.string,
    rateLimit: false,
    crossChain: true,
  },
  async ({ input }) => input.toUpperCase(),
);

indexer.onEvent(
  { contract: "Counters", event: "Bumped" },
  async ({ event, context }) => {
    const counter = await context.Counter.get("total");
    context.Counter.set({
      id: "total",
      count: (counter?.count ?? 0n) + event.params.amount,
    });

    const global = await context.GlobalCounter.get("total");
    context.GlobalCounter.set({
      id: "total",
      count: (global?.count ?? 0n) + event.params.amount,
    });

    context.Label.set({
      id: await context.effect(chainLabel, "counter"),
      value: await context.effect(shared, "counter"),
    });
  },
);
