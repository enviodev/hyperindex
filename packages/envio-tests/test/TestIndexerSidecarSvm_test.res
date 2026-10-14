// An SVM instruction shares its transaction's log index with the rest of the
// transaction, so its call id carries its position in the CPI tree, before the
// registration index.
let _ = InternalTestIndexer.fromUserApi(
  ~configYaml=`
name: test-indexer-sidecar-svm
ecosystem: svm
sidecar:
  contract: src/sidecar/contract.ts
  entry: src/sidecar/index.ts
chains:
  - id: solana
    start_slot: 100
programs:
  - name: Swapper
    program_id: 675kPX9MHTjS2zt1qfr1NYHuzeLXfQM9H24wFSUt1Mp8
    instructions:
      - name: swap
        discriminator: "0x09"
`,
  ~schema=`
type Probe {
  id: ID!
}
`,
  ~sidecarContract=`
import { defineSidecar, S } from "envio";

export default defineSidecar({
  functions: {
    notify: { input: { text: S.string } },
  },
});
`,
  ~handlers=`
import { indexer } from "envio";

indexer.onInstruction({ program: "Swapper", instruction: "swap" }, async ({ context }) => {
  context.sidecar.notify({ text: "swapped" });
});
`,
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("context.sidecar from an SVM instruction", () => {
  it("puts the instruction's CPI path in the call id", async (t) => {
    const indexer = createTestIndexer();
    const result = await indexer.process({
      chains: {
        7565164: {
          simulate: [
            { program: "Swapper", instruction: "swap", slot: 142, transaction: { transactionIndex: 4 }, path: [0] },
            { program: "Swapper", instruction: "swap", slot: 142, transaction: { transactionIndex: 4 }, path: [0, 2] },
          ],
        },
      },
    });

    t.expect(result.changes).toEqual([
      {
        block: 142,
        chainId: 7565164,
        eventsProcessed: 2,
        sidecar: {
          calls: [
            { id: "7565164:142:4.0r1:0", fn: "notify", input: { text: "swapped" } },
            { id: "7565164:142:4.0.2r2:0", fn: "notify", input: { text: "swapped" } },
          ],
        },
      },
    ]);
  });
});
`,
)
