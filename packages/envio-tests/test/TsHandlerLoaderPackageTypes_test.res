// Each handler's nearest package.json either has no `type` or says
// `commonjs`. Both handlers are written with `import`, which only runs as an ES
// module, so the loader must not give them the CommonJS format.
let _ = InternalTestIndexer.fromUserApi(
  ~configYaml=`
name: ts-loader-package-types
handlers: test/fixtures/ts_loader_package_types
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

describe("TypeScript handler loading in a non-module package", () => {
  it("runs ESM handler modules", async (t) => {
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

    const ids = (await indexer.Transfer.getAll()).map((transfer) => transfer.id).sort();
    t.expect(ids).toEqual(["commonjs", "untyped"]);
  });
});
`,
)
