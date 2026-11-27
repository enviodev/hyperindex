// Transaction handlers are EVM only: an SVM indexer refuses one at the call.
let _ = InternalTestIndexer.fromUserApi(
  ~configYaml=`
name: on-transaction-svm
ecosystem: svm
chains:
  - id: solana
    start_slot: 0
`,
  ~schema=`
type Noop {
  id: ID!
}
`,
  ~test=`
import { describe, it } from "vitest";
import { indexer } from "envio";

describe("onTransaction on SVM", () => {
  it("is refused", (t) => {
    t.expect(() =>
      (indexer as any).onTransaction({ name: "nope", where: () => true }, async () => {}),
    ).toThrowError(
      "\`indexer.onTransaction\` is supported on EVM chains only, and this indexer indexes svm.",
    );
  });
});
`,
)
