// A block handler selects how many transactions its block holds beside the
// block's header fields. Event registrations can't select it yet.
let _ = InternalTestIndexer.fromUserApi(
  ~configYaml=`
name: on-block-transaction-count
contracts:
  - name: Token
    events:
      - event: Transfer(address indexed from, address indexed to, uint256 value)
chains:
  - id: 1
    start_block: 0
    contracts:
      - name: Token
        address: "0x1111111111111111111111111111111111111111"
`,
  ~schema=`
type BlockCount {
  id: ID!
  timestamp: Int!
  transactions: Int!
}
`,
  ~handlers=`
import { indexer, type EvmBlockFieldName, type EvmEvent, type EvmOnEventOptions } from "envio";
import { expectType, type TypeEqual } from "ts-expect";

expectType<"transactionCount" extends EvmBlockFieldName ? true : false>(true);

indexer.onBlock(
  {
    name: "counts",
    where: () => ({ block: { number: { _gte: 1, _lte: 2 } } }),
    fields: { block: ["timestamp", "transactionCount"] },
  },
  async ({ block, context }) => {
    expectType<TypeEqual<typeof block.transactionCount, number>>(true);
    context.BlockCount.set({
      id: \`\${block.number}\`,
      timestamp: block.timestamp,
      transactions: block.transactionCount,
    });
  },
);

indexer.onBlock(
  { name: "timestamps", where: () => ({ block: { number: { _lte: 0 } } }), fields: { block: ["timestamp"] } },
  async ({ block }) => {
    // @ts-expect-error - transactionCount is not selected
    const _count: number = block.transactionCount;
  },
);

const countFields = { block: ["transactionCount"] } as const;
type TransferOptions = EvmOnEventOptions<EvmEvent<"Token", "Transfer">, {}, typeof countFields>;
expectType<
  TypeEqual<
    NonNullable<TransferOptions["fields"]>,
    typeof countFields & {
      readonly __blockHandlerOnlyField: "Field 'transactionCount' is not supported on indexer.onEvent yet. Select it in an indexer.onBlock handler instead.";
    }
  >
>(true);
`,
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer, indexer } from "envio";

describe("onBlock transaction count", () => {
  it("rejects the transaction count on an event handler", (t) => {
    t.expect(() =>
      indexer.onEvent(
        {
          contract: "Token",
          event: "Transfer",
          // @ts-expect-error - not supported on onEvent yet
          fields: { block: ["timestamp", "transactionCount"] },
        },
        async () => {},
      ),
    ).toThrowError(
      \`The "transactionCount" block field is not supported on \\\`indexer.onEvent\\\` yet. Select it in an \\\`indexer.onBlock\\\` handler instead, or remove it from the fields.block option of the "Transfer" event registration on contract "Token".\`,
    );
  });

  it("rejects the transaction count on a contract register handler", (t) => {
    t.expect(() =>
      indexer.contractRegister(
        {
          contract: "Token",
          event: "Transfer",
          // @ts-expect-error - not supported on contractRegister yet
          fields: { block: ["transactionCount"] },
        },
        async () => {},
      ),
    ).toThrowError(
      \`The "transactionCount" block field is not supported on \\\`indexer.contractRegister\\\` yet. Select it in an \\\`indexer.onBlock\\\` handler instead, or remove it from the fields.block option of the "Transfer" event registration on contract "Token".\`,
    );
  });

  it("hands a block handler its block's transaction count", async (t) => {
    const testIndexer = createTestIndexer();
    await testIndexer.process({
      chains: {
        1: {
          startBlock: 0,
          endBlock: 2,
          simulate: [
            { block: { number: 1, timestamp: 1_700_000_001, transactionCount: 7 } },
            { block: { number: 2, timestamp: 1_700_000_002, transactionCount: 0 } },
          ],
        },
      },
    });
    t.expect(
      (await testIndexer.BlockCount.getAll()).sort((a, b) => Number(a.id) - Number(b.id)),
    ).toEqual([
      { id: "1", timestamp: 1_700_000_001, transactions: 7 },
      { id: "2", timestamp: 1_700_000_002, transactions: 0 },
    ]);
  });
});
`,
)
