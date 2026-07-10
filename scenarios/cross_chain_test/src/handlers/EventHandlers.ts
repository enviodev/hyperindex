import { indexer } from "envio";

// Every chain increments the same "singleton" ids. The get-then-set exercises
// both read scoping and write isolation: Counter is per-chain (each chain only
// ever sees its own row), while GlobalCounter opted back into cross-chain
// sharing via @crossChain and accumulates across chains.
indexer.onEvent(
  { contract: "Counter", event: "Increment" },
  async ({ context }) => {
    const id = "singleton";
    const existing = await context.Counter.get(id);
    context.Counter.set({ id, count: (existing?.count ?? 0) + 1 });

    const global = await context.GlobalCounter.get(id);
    context.GlobalCounter.set({ id, count: (global?.count ?? 0) + 1 });
  }
);
