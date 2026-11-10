import { afterEach, beforeAll, describe, expect, it } from "vitest";

// envio's own TypeScript is loaded through the hooks `envio start` registers.
type Calls = typeof import("envio/src/subgraph/calls.ts");
let calls: Calls;
beforeAll(async () => {
  const { registerTsHooks } = await import("envio/src/HandlerLoader.res.mjs");
  registerTsHooks();
  calls = await import("envio/src/subgraph/calls.ts");
});
afterEach(() => {
  calls.resetSharedCalls();
  delete process.env.ENVIO_SUBGRAPH_EXACT_CALLS;
});

const token = "0xbb4cdb9cbd36b01bd1cbaebf2de08d9173bc095c";
const call = (signature: string, blockNumber: number, args: unknown[] = [], address = token) => ({
  chainId: 56,
  address,
  signature,
  args,
  blockNumber,
});
const value = (v: string) => JSON.stringify({ reverted: false, values: [v] });
const revert = JSON.stringify({ reverted: true, values: null });

/** Counts the asks and answers each from a table, as a node would. */
function node(answers: Record<string, string>) {
  const asked: string[] = [];
  const ask = (input: ReturnType<typeof call>) => async () => {
    asked.push(`${input.signature}@${input.blockNumber}`);
    await new Promise((resolve) => setTimeout(resolve, 5));
    return answers[`${input.signature}@${input.blockNumber}`] ?? answers[input.signature] ?? revert;
  };
  return { asked, ask };
}

describe("a stable function's answer, shared across blocks", () => {
  it("is asked once for every later block", async () => {
    const n = node({ "decimals()": value("i:18") });
    const outputs = [];
    for (const block of [100, 100, 250, 9000]) {
      const input = call("decimals()", block);
      outputs.push(await calls.shareAcrossBlocks(input, n.ask(input)));
    }
    expect({ asked: n.asked, outputs }).toEqual({
      asked: ["decimals()@100"],
      outputs: [value("i:18"), value("i:18"), value("i:18"), value("i:18")],
    });
  });

  it("waits for the one in flight instead of asking again", async () => {
    const n = node({ "symbol()": value("s:WBNB") });
    const inputs = [call("symbol()", 100), call("symbol()", 200), call("symbol()", 300)];
    const outputs = await Promise.all(inputs.map((input) => calls.shareAcrossBlocks(input, n.ask(input))));
    expect({ asked: n.asked, outputs }).toEqual({
      asked: ["symbol()@100"],
      outputs: [value("s:WBNB"), value("s:WBNB"), value("s:WBNB")],
    });
  });

  it("never answers an earlier block from a later one", async () => {
    const n = node({ "symbol()@500": value("s:ABC"), "symbol()@50": revert });
    const late = call("symbol()", 500);
    const early = call("symbol()", 50);
    const results = [
      await calls.shareAcrossBlocks(late, n.ask(late)),
      // The token isn't deployed yet at block 50: that is its own answer.
      await calls.shareAcrossBlocks(early, n.ask(early)),
    ];
    expect({ asked: n.asked, results }).toEqual({
      asked: ["symbol()@500", "symbol()@50"],
      results: [value("s:ABC"), revert],
    });
  });

  it("does not share a revert, a zero address or an empty string", async () => {
    const zero = value("s:0x0000000000000000000000000000000000000000");
    const pair = ["s:0xAAAA000000000000000000000000000000000001", "s:0xaaaa000000000000000000000000000000000002"];
    const n = node({
      "getPair(address,address)@10": zero,
      "getPair(address,address)@20": value("s:0x1111111111111111111111111111111111111111"),
      "name()@10": value("s:"),
    });
    const out: string[] = [];
    for (const input of [
      call("getPair(address,address)", 10, pair),
      // Created in between: asked again, and from here on shared.
      call("getPair(address,address)", 20, pair),
      call("getPair(address,address)", 30, pair.map((a) => a.toLowerCase())),
      call("name()", 10),
      call("name()", 11),
    ]) {
      out.push(await calls.shareAcrossBlocks(input, n.ask(input)));
    }
    expect({ asked: n.asked, shared: out[2] === out[1] }).toEqual({
      asked: [
        "getPair(address,address)@10",
        "getPair(address,address)@20",
        "name()@10",
        "name()@11",
      ],
      shared: true,
    });
  });

  it("leaves other functions pinned to their block", async () => {
    const n = node({ "getReserves()": value("i:1") });
    for (const block of [1, 2, 3]) {
      const input = call("getReserves()", block);
      await calls.shareAcrossBlocks(input, n.ask(input));
    }
    expect(n.asked).toEqual(["getReserves()@1", "getReserves()@2", "getReserves()@3"]);
  });

  it("asks every block when ENVIO_SUBGRAPH_EXACT_CALLS=1", async () => {
    process.env.ENVIO_SUBGRAPH_EXACT_CALLS = "1";
    const n = node({ "decimals()": value("i:18") });
    for (const block of [1, 2]) {
      const input = call("decimals()", block);
      await calls.shareAcrossBlocks(input, n.ask(input));
    }
    expect(n.asked).toEqual(["decimals()@1", "decimals()@2"]);
  });
});
