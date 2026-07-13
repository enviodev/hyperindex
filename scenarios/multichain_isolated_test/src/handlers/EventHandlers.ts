import { indexer } from "envio";

// Every chain increments the same "singleton" Counter. The get-then-set
// exercises both read scoping and write isolation: each chain only ever sees
// and updates its own row.
indexer.onEvent(
  { contract: "Counter", event: "Increment" },
  async ({ context }) => {
    const id = "singleton";
    const existing = await context.Counter.get(id);
    context.Counter.set({ id, count: (existing?.count ?? 0) + 1 });
  }
);
