import { describe, expect, it } from "vitest";
import { graftBaseNotice, readManifest } from "../../envio/src/subgraph/graft.ts";

const manifests: Record<string, string> = {
  QmChild: `specVersion: 1.1.0
graft:
  base: QmRoot
  block: 500
dataSources:
  - name: A
    source:
      startBlock: 700
`,
  QmRoot: `specVersion: 1.1.0
dataSources:
  - name: A
    source:
      startBlock: 100
  - name: B
    source:
      startBlock: 300
`,
};
const fetchManifest = async (hash: string) => manifests[hash] ?? null;

describe("graft base check", () => {
  it("reads start blocks and the graft of a deployment manifest", () => {
    expect([readManifest(manifests.QmChild), readManifest(manifests.QmRoot)]).toEqual([
      { startBlocks: [700], graft: { base: "QmRoot", block: 500 } },
      { startBlocks: [100, 300], graft: null },
    ]);
  });

  it("names the missing blocks when the base started before every data source here", async () => {
    expect(await graftBaseNotice({ base: "QmChild", block: 900 }, [800], fetchManifest)).toBe(
      "WARNING, DATA IS MISSING: the graft base QmChild (read from IPFS) starts at block 100, but the earliest " +
        "startBlock here is 800. Blocks 100 to 799 are in the grafted deployment and will not be indexed. " +
        "Lower the startBlock of the data sources to 100 to rebuild that history.",
    );
  });

  it("says a re-index covers the base when no data source starts later than it", async () => {
    expect(await graftBaseNotice({ base: "QmRoot", block: 500 }, [100], fetchManifest)).toBe(
      "The graft base QmRoot (read from IPFS) starts at block 100, not after this manifest's earliest startBlock 100: " +
        "a re-index covers the same blocks.",
    );
  });

  it("says nothing when the base cannot be read", async () => {
    expect(await graftBaseNotice({ base: "QmGone", block: 1 }, [1], fetchManifest)).toBeNull();
  });
});
