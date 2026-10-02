// A syntax error names the line and column and shows the code around it,
// instead of a bare "Unexpected token".
let _ = InternalTestIndexer.fromUserApi(
  ~configYaml=`
name: ts-loader-syntax-error
handlers: test/fixtures/ts_loader_syntax_error
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

describe("TypeScript handler with a syntax error", () => {
  it("fails with the location and a code frame", async (t) => {
    const indexer = createTestIndexer();
    const file = join(process.cwd(), "test/fixtures/ts_loader_syntax_error/TransferHandlers.ts");

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
      \`Failed to auto-load handler file: test/fixtures/ts_loader_syntax_error/TransferHandlers.ts. Cause: Error: Failed parsing \${file}:
  × Unexpected token
   ╭─[\${file}:4:41]
 3 │ indexer.onEvent({ contract: "Token", event: "Transfer" }, async ({ context }) => {
 4 │   context.Transfer.set({ id: "broken" + });
   ·                                         ─
 5 │ });
   ╰────
\`
    );
  });
});
`,
)
