// Transaction handlers are EVM only: a Fuel indexer refuses one at the call.
let _ = InternalTestIndexer.fromUserApi(
  ~configYaml=`
name: on-transaction-fuel
ecosystem: fuel
chains:
  - id: 0
    start_block: 0
    contracts: []
`,
  ~schema=`
type Noop {
  id: ID!
}
`,
  ~test=`
import { describe, it } from "vitest";
import { indexer } from "envio";

describe("onTransaction on Fuel", () => {
  it("is refused", (t) => {
    t.expect(() =>
      (indexer as any).onTransaction({ name: "nope", where: () => true }, async () => {}),
    ).toThrowError(
      "\`indexer.onTransaction\` is supported on EVM chains only, and this indexer indexes fuel.",
    );
  });
});
`,
)
