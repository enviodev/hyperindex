import assert from "assert";
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

const bump = (amount: bigint) => ({
  contract: "Counters" as const,
  event: "Bumped" as const,
  params: { amount },
});

// Both chains bump the same entity ids, which is exactly the collision the
// per-chain mode is meant to keep apart.
const processBothChains = async () => {
  const indexer = createTestIndexer();
  const result = await indexer.process({
    chains: {
      1: { startBlock: 1, endBlock: 10, simulate: [bump(1n), bump(2n)] },
      137: { startBlock: 1, endBlock: 10, simulate: [bump(10n)] },
    },
  });
  return { indexer, result };
};

describe("per-chain entities", () => {
  it("keeps the same entity id apart per chain", async () => {
    const { indexer } = await processBothChains();

    const counters = await indexer.Counter.getAll();
    assert.deepEqual(
      counters.sort((a, b) => a.chainId - b.chainId),
      [
        { id: "total", count: 3n, chainId: 1 },
        { id: "total", count: 10n, chainId: 137 },
      ],
    );
  });

  it("merges a @crossChain entity into one row", async () => {
    const { indexer } = await processBothChains();

    assert.deepEqual(await indexer.GlobalCounter.getAll(), [
      { id: "total", count: 13n },
    ]);
  });

  it("reports the chain on each change", async () => {
    const { result } = await processBothChains();
    const { changes } = result;

    // A change belongs to one chain, so the per-chain Counter inside it doesn't
    // repeat the chain id. The cross-chain GlobalCounter accumulates across both.
    assert.deepEqual(
      changes.map((change) => ({
        chainId: change.chainId,
        counter: change.Counter?.sets,
        global: change.GlobalCounter?.sets,
      })),
      [
        {
          chainId: 1,
          counter: [{ id: "total", count: 3n }],
          global: [{ id: "total", count: 3n }],
        },
        {
          chainId: 137,
          counter: [{ id: "total", count: 10n }],
          global: [{ id: "total", count: 13n }],
        },
      ],
    );
  });

  it("throws when an id exists on more than one chain", async () => {
    const { indexer } = await processBothChains();

    assert.throws(
      () => indexer.Counter.get("total"),
      /Entity `Counter` with id `total` exists on multiple chains \(1, 137\) — use getWhere\(\{chainId: \{_eq: \.\.\.\}\}\) to pick one/,
    );
  });

  it("resolves the ambiguity with getWhere on chainId", async () => {
    const { indexer } = await processBothChains();

    assert.deepEqual(
      await indexer.Counter.getWhere({ chainId: { _eq: 137 } }),
      [{ id: "total", count: 10n, chainId: 137 }],
    );
  });

  it("filters a per-chain entity by an ordinary field too", async () => {
    const { indexer } = await processBothChains();

    assert.deepEqual(
      await indexer.Counter.getWhere({ count: { _gte: 10n } }),
      [{ id: "total", count: 10n, chainId: 137 }],
    );
  });

  it("has no chainId to filter on for a @crossChain entity", async () => {
    const { indexer } = await processBothChains();

    assert.deepEqual(
      await indexer.GlobalCounter.getWhere({ id: { _eq: "total" } }),
      [{ id: "total", count: 13n }],
    );
    assert.throws(
      // @ts-expect-error a cross-chain entity has no chainId field
      () => indexer.GlobalCounter.getWhere({ chainId: { _eq: 1 } }),
      /Invalid field "chainId" in context.GlobalCounter.getWhere\(\)/,
    );
  });

  it("requires a chainId when setting a per-chain entity directly", async () => {
    const indexer = createTestIndexer();
    assert.throws(
      // @ts-expect-error chainId is required on a per-chain entity
      () => indexer.Counter.set({ id: "total", count: 1n }),
      /Counter\.set\(\) requires a `chainId` because the entity is per-chain/,
    );

    indexer.Counter.set({ id: "total", count: 1n, chainId: 1 });
    assert.deepEqual(await indexer.Counter.getAll(), [
      { id: "total", count: 1n, chainId: 1 },
    ]);
  });
});

describe("effect scopes", () => {
  it("scopes an effect per chain unless it opts out", async () => {
    const { indexer } = await processBothChains();

    // `chainLabel` states no scope, so the config's disabled default makes it
    // per-chain and its output differs per chain. `shared` is cross-chain and
    // produces the same value everywhere.
    const labels = await indexer.Label.getAll();
    assert.deepEqual(
      labels.sort((a, b) => a.id.localeCompare(b.id)),
      [
        { id: "counter@1", value: "COUNTER", chainId: 1 },
        { id: "counter@137", value: "COUNTER", chainId: 137 },
      ],
    );
  });
});
