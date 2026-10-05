// The handler's nearest package.json has no `"type": "module"`. Handlers load
// only as ES modules, so the user gets told how to switch rather than an error
// from deep inside Node's module loader.
let _ = InternalTestIndexer.fromUserApi(
  ~configYaml=`
name: ts-loader-commonjs
handlers: test/fixtures/ts_loader_commonjs
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
import { join } from "node:path";
import { createTestIndexer, TestHelpers } from "envio";

const { Addresses } = TestHelpers;

describe("TypeScript handler loading in a CommonJS package", () => {
  it("fails with a pointer to \\"type\\": \\"module\\"", async (t) => {
    const indexer = createTestIndexer();
    const fixture = join(process.cwd(), "test/fixtures/ts_loader_commonjs");

    const error = await indexer
      .process({
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
      })
      .then(
        () => undefined,
        (error: Error) => error.message
      );

    t.expect(error).toBe(
      \`Failed to auto-load handler file: test/fixtures/ts_loader_commonjs/TransferHandlers.ts. Cause: Error: \${join(fixture, "TransferHandlers.ts")} can't load: envio handlers are ES modules, and \${join(fixture, "package.json")} doesn't declare them. Add "type": "module" to it.\`
    );
  });
});
`,
)
