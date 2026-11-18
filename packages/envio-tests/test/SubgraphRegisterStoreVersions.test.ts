import { beforeAll, describe, expect, it } from "vitest";

// envio's own TypeScript is loaded through the hooks `envio start` registers.
type GraphTs = typeof import("envio/src/subgraph/graph-ts.ts");
let graphTs: GraphTs;
beforeAll(async () => {
  const { registerTsHooks } = await import("envio/src/HandlerLoader.res.mjs");
  registerTsHooks();
  graphTs = await import("envio/src/subgraph/graph-ts.ts");
});

type Version = { position: number; row: Record<string, unknown> | null };
const at = (block: number, round: number, logIndex: number) =>
  block * graphTs.POSITION_BLOCK + round * graphTs.ROUND_SPAN + logIndex;
const add = (versions: Version[], position: number) =>
  graphTs.addRegisterVersion(versions, { position, row: { position } });

// A register pass reads the newest version below its own position. A block's
// creation rounds run out of log order, so a round-1 event logged before the
// deployer reads the deployer's write, with the other round-1 passes' writes
// of the same entity above it. Four versions in all dropped that write.
describe("register store versions", () => {
  it("keeps the deployer's write under a block's later rounds of writes", () => {
    const versions: Version[] = [];
    add(versions, at(100, 0, 101));
    for (let logIndex = 99; logIndex >= 90; logIndex--) add(versions, at(100, 1, logIndex));

    expect(versions).toHaveLength(11);
    expect(versions[0].position).toBe(at(100, 0, 101));
    expect(versions.filter((version) => version.position < at(100, 1, 92))).toHaveLength(3);
  });

  it("keeps the newest four versions of earlier blocks and the newest block's own", () => {
    const versions: Version[] = [];
    for (let block = 1; block <= 8; block++) add(versions, at(block, 0, 5));
    expect(versions.map((version) => Math.floor(version.position / graphTs.POSITION_BLOCK))).toEqual([4, 5, 6, 7, 8]);

    add(versions, at(9, 0, 5));
    add(versions, at(9, 1, 1));
    expect(versions.map((version) => Math.floor(version.position / graphTs.POSITION_BLOCK))).toEqual([5, 6, 7, 8, 9, 9]);
  });

  // A data source created at a block gets a partition of its own that starts
  // there, while the others fetch ahead and keep writing: Reserve's Timelock
  // passes at its creation block read the RToken and RTokenContract the Main
  // passes wrote there, under many later versions. Below the lowest partition
  // frontier no pass can read any more, so only there is anything dropped.
  it("keeps every version a pass at or above the fetch frontier can read", () => {
    const versions: Version[] = [];
    const floor = at(50, 0, 0);
    for (let block = 10; block <= 200; block += 10) graphTs.addRegisterVersion(versions, { position: at(block, 0, 1), row: {} }, floor);
    expect(versions.map((version) => Math.floor(version.position / graphTs.POSITION_BLOCK))).toEqual([
      40, 50, 60, 70, 80, 90, 100, 110, 120, 130, 140, 150, 160, 170, 180, 190, 200,
    ]);
  });

  it("bounds the newest block's own versions", () => {
    const versions: Version[] = [];
    add(versions, at(1, 0, 1));
    for (let logIndex = 0; logIndex < 500; logIndex++) add(versions, at(2, 0, logIndex));
    expect(versions.length).toBeLessThanOrEqual(1 + 64);
    expect(versions[versions.length - 1].position).toBe(at(2, 0, 499));
  });
});
