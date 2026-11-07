import { afterEach, beforeAll, describe, expect, it } from "vitest";

// The register pass runs a factory's mapping at fetch time, outside any
// handler context, so its contract calls never went through the effect cache:
// after `envio start -r`, which keeps the cached calls (SubgraphCallCacheReset),
// a resync still asked the RPC again for every call a register pass makes
// (sushiswap v3: 756 of the 1,643 calls of its first batches). It now reads the
// stored answers first, one storage query for the calls a turn asks.
type Lookup = typeof import("envio/src/EffectCacheLookup.res.mjs");
let lookup: Lookup;
beforeAll(async () => {
  const { registerTsHooks } = await import("envio/src/HandlerLoader.res.mjs");
  registerTsHooks();
  lookup = await import("envio/src/EffectCacheLookup.res.mjs");
});

const g = globalThis as any;
const saved = g.__envioGlobal?.persistence;
afterEach(() => {
  if (g.__envioGlobal) g.__envioGlobal.persistence = saved;
  lookup.resetStartupTables();
});

// What the effect machinery stores for a string input: its JSON text.
const keyOf = (input: string) => `"${input}"`;

function storage(rows: Record<string, string>, tables: Record<string, number>) {
  const queries: string[][] = [];
  const persistence = {
    storageStatus: {
      TAG: "Ready",
      _0: {
        cache: Object.fromEntries(Object.entries(tables).map(([tableName, count]) => [tableName, { tableName, count }])),
      },
    },
    storage: {
      // Labeled arguments arrive in declaration order: filter, table.
      loadOrThrow: async (filter: any) => {
        const ids: string[] = filter.id._in;
        queries.push(ids);
        return ids.filter((id) => id in rows).map((id) => ({ id, output: rows[id] }));
      },
    },
  };
  return { persistence, queries };
}

describe("the register pass's contract calls", () => {
  it("are answered from the stored cache, in one query per turn", async () => {
    const { persistence, queries } = storage(
      { [keyOf("call-a")]: "answer-a", [keyOf("call-b")]: "answer-b" },
      { envio_1_effect_envio_subgraph_eth_call: 2 },
    );
    g.__envioGlobal.persistence = persistence;
    const { createEffect } = await import("envio/src/Envio.res.mjs");
    const S = await import("rescript-schema");
    const call = (createEffect as any)(
      { name: "envio_subgraph_eth_call", input: S.string, output: S.string, rateLimit: false, cache: true, crossChain: false },
      async () => "asked",
    );
    const answers = await Promise.all(["call-a", "call-b", "call-c"].map((input) => lookup.cached(call, 1, input)));
    expect({ answers, queries: queries.length }).toEqual({ answers: ["answer-a", "answer-b", undefined], queries: 1 });
  });

  it("aren't looked up for a table this run started without", async () => {
    const { persistence, queries } = storage({ [keyOf("call-a")]: "answer-a" }, {});
    g.__envioGlobal.persistence = persistence;
    const { createEffect } = await import("envio/src/Envio.res.mjs");
    const S = await import("rescript-schema");
    const call = (createEffect as any)(
      { name: "envio_subgraph_eth_call", input: S.string, output: S.string, rateLimit: false, cache: true, crossChain: false },
      async () => "asked",
    );
    expect({ answer: await lookup.cached(call, 1, "call-a"), queries: queries.length }).toEqual({
      answer: undefined,
      queries: 0,
    });
  });
});
