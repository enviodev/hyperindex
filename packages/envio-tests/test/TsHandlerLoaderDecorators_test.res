// Only TypeScript's legacy decorators can be lowered, and Node can't run the
// standard ones yet, so without `experimentalDecorators` a decorator is an
// error that says what to change rather than a SyntaxError from Node.
let _ = InternalTestIndexer.fromUserApi(
  ~configYaml=`
name: ts-loader-decorators
handlers: test/fixtures/ts_loader_decorators
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

describe("TypeScript handler with a decorator", () => {
  it("fails with a pointer to experimentalDecorators", async (t) => {
    const indexer = createTestIndexer();
    const file = join(process.cwd(), "test/fixtures/ts_loader_decorators/TransferHandlers.ts");

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
      \`Failed to auto-load handler file: test/fixtures/ts_loader_decorators/TransferHandlers.ts. Cause: Error: Failed transforming \${file}:
  × Decorators need "experimentalDecorators": true in tsconfig.json.
   ╭─[\${file}:6:3]
 5 │ class Counter {
 6 │   @logged
   ·   ───────
 7 │   count() {
   ╰────
\`
    );
  });
});
`,
)
