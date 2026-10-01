// The handler's nearest package.json has no `type`. Node gives an ambiguous
// `.ts` file written with `import` the module format, so the loader must too
// rather than running it as CommonJS.
let _ = InternalTestIndexer.fromUserApi(
  ~configYaml=`
name: ts-loader-untyped
handlers: test/fixtures/ts_loader_untyped
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

describe("TypeScript handler loading without a package type", () => {
  it("runs an ESM handler module", async (t) => {
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
