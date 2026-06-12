import assert from "assert";
import { it, describe } from "vitest";
import { createTestIndexer } from "envio";

// Reproduction for the TestIndexer crash reported against envio 3.2.0:
//
//   TypeError: Cannot read properties of undefined (reading 'table')
//    ❯ parseLeaf   node_modules/envio/src/TestIndexer.res.mjs
//    ❯ mapValues   node_modules/envio/src/db/EntityFilter.res.mjs
//    ❯ handleLoad  node_modules/envio/src/TestIndexer.res.mjs
//
// `handleLoad` looks up `state.entityConfigs[tableName]` and unconditionally
// dereferences `.table`. Every entity load passes the entity's own table name
// (always present in `entityConfigs`), so the report's "read an entity back"
// framing is a red herring. The one `loadOrThrow` whose table is NOT an entity
// is the cached-effect load (`LoadLayer.loadByEffect` -> effect.storageMeta.table,
// tableName `envio_effect_<EffectName>`). That table is absent from
// `entityConfigs`, so the lookup is `undefined` and `.table` throws.
//
// The load only fires once the effect cache has been committed by an earlier
// batch and a LATER batch requests a not-yet-in-memory cache key — i.e. a
// multi-batch run with a cached effect. Single-batch simulate runs never hit
// it, which matches the report ("single-event tests pass"). This project sets
// `full_batch_size: 1` so a two-block simulate splits into two batches, the way
// a real multi-block indexer does.
describe("Repro: TestIndexer handleLoad crash on cross-batch cached-effect load", () => {
  it("does not crash when a cached effect is loaded back in a later batch", async () => {
    const indexer = createTestIndexer();
    const dc = "0x1234567890123456789012345678901234567890";

    // Block 1 caches effect key "1" and commits it (registers the effect in the
    // worker's persistence cache). Block 2 requests a fresh effect key "2",
    // which is not in the in-memory effect table, so the runtime issues a
    // storage load of the effect cache table -> handleLoad("envio_effect_...").
    await assert.doesNotReject(
      indexer.process({
        chains: {
          1337: {
            startBlock: 1,
            endBlock: 2,
            simulate: [
              {
                contract: "Gravatar",
                event: "FactoryEvent",
                params: { contract: dc, testCase: "testEffectWithCache" },
                block: { number: 1 },
              },
              {
                contract: "Gravatar",
                event: "FactoryEvent",
                params: { contract: dc, testCase: "testEffectWithCache2" },
                block: { number: 2 },
              },
            ],
          },
        },
      }),
    );
  });
});
