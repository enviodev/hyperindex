// No `~handlers` source: `createTestIndexer` loads `test/fixtures/ts_loader`
// through `HandlerLoader`, as a project's `src/handlers` is loaded, rather than
// through vite. The fixture uses what Node cannot run as-is: a non-erasable
// `enum`, an extensionless relative import, a `.js` specifier resolving to a
// `.ts` sibling, and a JSON import without an import attribute.
let _ = InternalTestIndexer.fromUserApi(
  ~configYaml=`
name: ts-loader
handlers: test/fixtures/ts_loader
chains:
  - id: 1
    start_block: 0
    contracts:
      - name: Token
        address: "0x1111111111111111111111111111111111111111"
        events:
          - event: Transfer(address indexed from, address indexed to, uint256 value)
`,
  ~schema=`
type Transfer {
  id: ID!
  direction: String!
}
`,
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer, TestHelpers } from "envio";

const { Addresses } = TestHelpers;

describe("TypeScript handler loading", () => {
  it("runs a handler module with non-erasable syntax and bundler-style imports", async (t) => {
    const indexer = createTestIndexer();

    await indexer.process({
      chains: {
        1: {
          simulate: [
            {
              contract: "Token",
              event: "Transfer",
              params: { from: Addresses.mockAddresses[1], to: Addresses.defaultAddress, value: 1n },
            },
          ],
        },
      },
    });

    t.expect(await indexer.Transfer.getAll()).toEqual([{ id: "1_0_0", direction: "js:incoming:ts" }]);
  });
});
`,
)
