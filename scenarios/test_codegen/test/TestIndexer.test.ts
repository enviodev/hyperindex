import assert from "assert";
import { it, describe } from "vitest";
import { createTestIndexer } from "envio";

const dc = "0x1234567890123456789012345678901234567890";

describe("TestIndexer", () => {
  // Reproduction for the crash reported against envio 3.2.0:
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
  // It only fires across batches: an effect cached & committed in one batch,
  // then re-requested with a fresh key in a LATER batch, whose preload loads the
  // cache from storage. Registering a dynamic contract at a later block than a
  // prior event is enough to split a single simulate run into two batches (the
  // earlier blocks commit first) — the same shape the reporter hit with
  // SafeSetup at block N then ProxyCreation's contractRegister at block N+1.
  it("does not crash when a cached effect is loaded back in a batch split off by a later contract registration", async () => {
    const indexer = createTestIndexer();

    // Block 2 caches effect key "1" and commits it (batch 1). Block 3 registers
    // a dynamic contract — which splits it into a second batch — and re-calls
    // the cached effect with a fresh key, so batch 2's preload loads the effect
    // cache table -> handleLoad("envio_effect_testEffectWithCache").
    await assert.doesNotReject(
      indexer.process({
        chains: {
          1337: {
            startBlock: 1,
            endBlock: 10,
            simulate: [
              {
                contract: "Gravatar",
                event: "FactoryEvent",
                params: { contract: dc, testCase: "testEffectWithCache" },
                block: { number: 2 },
              },
              {
                contract: "Gravatar",
                event: "FactoryEvent",
                params: { contract: dc, testCase: "registerAndCachedEffect" },
                block: { number: 3 },
              },
            ],
          },
        },
      }),
    );
  });
});
