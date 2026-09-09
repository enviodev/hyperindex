// Names that are keywords in the generated languages reach codegen capitalized,
// so they land in identifier positions as `Module`/`Lazy`/`Type` and the
// generated ReScript and TypeScript both accept them.
let _ = InternalTestIndexer.fromUserApi(
  ~configYaml=`
name: reserved-names
chains:
  - id: 1
    start_block: 0
    contracts:
      - name: Token
        address: "0x1111111111111111111111111111111111111111"
        events:
          - event: module(address indexed to, uint256 value)
`,
  ~schema=`
enum type {
  open
  switch
}
type lazy {
  id: ID!
  balance: BigInt!
  kind: type!
}
`,
  ~handlers=`
import { indexer } from "envio";

indexer.onEvent({ contract: "Token", event: "module" }, async ({ event, context }) => {
  context.Lazy.set({
    id: event.params.to,
    balance: event.params.value,
    kind: "open",
  });
});
`,
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer, type Lazy, TestHelpers } from "envio";

const { Addresses } = TestHelpers;

describe("keyword names", () => {
  it("indexes an event, entity and enum named after language keywords", async (t) => {
    const indexer = createTestIndexer();
    const to = Addresses.defaultAddress;

    await indexer.process({
      chains: {
        1: {
          simulate: [
            { contract: "Token", event: "module", params: { to, value: 5n } },
          ],
        },
      },
    });

    const expected: Lazy = { id: to, balance: 5n, kind: "open" };
    t.expect(await indexer.Lazy.getOrThrow(to)).toEqual(expected);
  });
});
`,
)
