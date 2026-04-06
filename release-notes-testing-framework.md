# New: `createTestIndexer()` — A Complete Testing Framework

HyperIndex now ships a purpose-built testing framework powered by `createTestIndexer()`. Write tests against the same indexer that runs in production — no database, no Docker, no manual mock wiring.

## Three ways to feed events

- **Auto-exit** — processes the first block with matching events, then exits. Each subsequent call continues where the last one stopped. Zero config needed.
- **Explicit block range** — pin to specific blocks for deterministic CI snapshots.
- **Simulate** — feed typed synthetic events for pure unit tests. No network, no block ranges.

## Auto-exit example — test against real on-chain data with zero config

```ts
import { describe, it } from "vitest";
import { createTestIndexer } from "generated";

describe("ERC20 indexer", () => {
  it("processes the first block with events", async (t) => {
    const indexer = createTestIndexer();

    const result = await indexer.process({ chains: { 1: {} } });

    // Auto-filled by Vitest on first run — just review and commit
    t.expect(result).toMatchInlineSnapshot(`
      {
        "changes": [
          {
            "Transfer": {
              "sets": [
                {
                  "blockNumber": 10861674,
                  "from": "0x0000000000000000000000000000000000000000",
                  "id": "1-10861674-23",
                  "to": "0x41653c7d61609D856f29355E404F310Ec4142Cfb",
                  "transactionHash": "0x4b37d2f343608457ca...",
                  "value": 1000000000000000000000000000n,
                },
              ],
            },
            "block": 10861674,
            "chainId": 1,
            "eventsProcessed": 1,
          },
        ],
      }
    `);
  });
});
```

## Highlights

- **Snapshot-driven assertions** — `result.changes` captures every entity set/delete per block. Pair with `toMatchInlineSnapshot` for auto-generated, reviewable snapshots.
- **Direct entity access** — `indexer.Entity.get()`, `.getOrThrow()`, `.getAll()`, and `.set()` for reading and presetting state.
- **Real pipeline, real confidence** — tests exercise the full indexer pipeline including dynamic contract registration, multi-chain support, and handler context.

---

# Deprecated: `MockDb`

The `MockDb` testing API has been removed. Migrate to `createTestIndexer()` with `simulate`:

```diff
-import { TestHelpers, type User } from "generated";
-const { MockDb, Greeter, Addresses } = TestHelpers;
+import { createTestIndexer, type User } from "generated";
+import { TestHelpers } from "envio";
+const { Addresses } = TestHelpers;

 it("A NewGreeting event creates a User entity", async (t) => {
-  const mockDbInitial = MockDb.createMockDb();
+  const indexer = createTestIndexer();
   const userAddress = Addresses.defaultAddress;
   const greeting = "Hi there";

-  const mockNewGreetingEvent = Greeter.NewGreeting.createMockEvent({
-    greeting: greeting,
-    user: userAddress,
-  });
-
-  const updatedMockDb = await Greeter.NewGreeting.processEvent({
-    event: mockNewGreetingEvent,
-    mockDb: mockDbInitial,
+  await indexer.process({
+    chains: {
+      137: {
+        simulate: [
+          {
+            contract: "Greeter",
+            event: "NewGreeting",
+            params: { greeting, user: userAddress },
+          },
+        ],
+      },
+    },
   });

   const expectedUserEntity: User = {
     id: userAddress,
     latestGreeting: greeting,
     numberOfGreetings: 1,
     greetings: [greeting],
   };

-  const actualUserEntity = updatedMockDb.entities.User.get(userAddress);
+  const actualUserEntity = await indexer.User.getOrThrow(userAddress);
   t.expect(actualUserEntity).toEqual(expectedUserEntity);
 });
```

## Migration cheat sheet

| Old (`MockDb`) | New (`createTestIndexer`) |
|---|---|
| `MockDb.createMockDb()` | `createTestIndexer()` |
| `Contract.Event.createMockEvent({...})` | Inline in `simulate: [{ contract, event, params }]` |
| `Contract.Event.processEvent({event, mockDb})` | `indexer.process({ chains: { id: { simulate } } })` |
| `mockDb.entities.Entity.get(id)` | `await indexer.Entity.getOrThrow(id)` |
| `mockDb.entities.Entity.set({...})` | `indexer.Entity.set({...})` |
| Manual handler threading & event chaining | Automatic — pass multiple events in the `simulate` array |
