import { beforeAll, describe, expect, it } from "vitest";

// envio's own TypeScript is loaded through the hooks `envio start` registers.
type GraphTs = typeof import("envio/src/subgraph/graph-ts.ts");
type GraphNodeDecimal = typeof import("envio/src/subgraph/graph-node-decimal.ts");
let graphTs: GraphTs;
let decimal: GraphNodeDecimal;
beforeAll(async () => {
  const { registerTsHooks } = await import("envio/src/HandlerLoader.res.mjs");
  registerTsHooks();
  graphTs = await import("envio/src/subgraph/graph-ts.ts");
  decimal = await import("envio/src/subgraph/graph-node-decimal.ts");
});

// Uniswap v3's bigDecimalExponated multiplies by the base one step at a time,
// and `times` keeps each step's product to answer the same step again. Every
// step must be the product graph-node rounds, however the chain is reached:
// `x.times(base)`, `base.times(x)`, a base parsed again, a negative base, a
// base of 34 digits, and a chain computed a second time.
describe("BigDecimal power chains", () => {
  it("give every step the product an unchained multiplication does", () => {
    const steps = 300;
    const results: Record<string, boolean> = {};
    for (const text of ["1.0001", "-1.0001", "0.9999", "1.234567890123456789012345678901234", "-7.5"]) {
      const base = graphTs.BigDecimal.fromString(text);
      const expected = [base.decimal];
      for (let k = 0; k < steps; k++) {
        expected.push(decimal.renormalize(decimal.multiply(expected[k]!, base.decimal)));
      }
      for (const [order, step] of [
        ["x.times(base)", (x: typeof base) => x.times(base)],
        ["base.times(x)", (x: typeof base) => base.times(x)],
        ["x.times(parsed)", (x: typeof base) => x.times(graphTs.BigDecimal.fromString(text))],
        ["again", (x: typeof base) => x.times(base)],
      ] as const) {
        let x = graphTs.BigDecimal.zero().plus(base);
        let same = true;
        for (let k = 1; k <= steps; k++) {
          x = step(x);
          same &&= x.decimal.int === expected[k]!.int && x.decimal.scale === expected[k]!.scale;
        }
        results[`${text} ${order}`] = same;
      }
    }
    expect(Object.values(results).every(Boolean) ? "all match" : results).toBe("all match");
  });
});
