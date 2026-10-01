// The handlers directory has its own tsconfig.json, extending a base that maps
// `@lib/*` through `paths` and resolves bare `lib/...` against `baseUrl`, which
// TypeScript accepts and Node's resolver knows nothing about.
let _ = InternalTestIndexer.fromUserApi(
  ~configYaml=`
name: ts-loader-paths
handlers: test/fixtures/ts_loader_paths
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
}
`,
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer, TestHelpers } from "envio";

const { Addresses } = TestHelpers;

describe("TypeScript handler loading with tsconfig paths", () => {
  it("resolves paths aliases and baseUrl imports", async (t) => {
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

    t.expect(await indexer.Transfer.getAll()).toEqual([{ id: "1_0_0" }]);
  });
});
`,
)
