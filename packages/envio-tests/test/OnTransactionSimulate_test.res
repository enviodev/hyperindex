// A simulated transaction runs the transaction handlers whose filter matches
// it, with the fields it was given, the way a source routes a fetched one.
let _ = InternalTestIndexer.fromUserApi(
  ~configYaml=`
name: on-transaction-simulate
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
type Seen {
  id: ID!
  from: String!
  value: BigInt!
  status: Int!
  timestamp: Int!
}
`,
  ~handlers=`
import { indexer } from "envio";

const alice = "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const token = "0x1111111111111111111111111111111111111111";

indexer.onTransaction(
  {
    name: "from-alice",
    where: () => ({ transaction: { from: [alice] } }),
    fields: { transaction: ["value", "status"], block: ["timestamp"] },
  },
  async ({ transaction, block, context }) => {
    context.Seen.set({
      id: \`from-alice:\${block.number}:\${transaction.transactionIndex}\`,
      from: transaction.from ?? "none",
      value: transaction.value,
      status: transaction.status ?? -1,
      timestamp: block.timestamp,
    });
  },
);

indexer.onTransaction(
  { name: "token-ok", where: () => ({ transaction: { to: [token], sighash: ["0xa9059cbb"], status: 1 } }) },
  async ({ transaction, block, context }) => {
    context.Seen.set({
      id: \`token-ok:\${block.number}:\${transaction.transactionIndex}\`,
      from: transaction.from ?? "none",
      value: 0n,
      status: -1,
      timestamp: -1,
    });
  },
);
`,
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

const alice = "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const bob = "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
const token = "0x1111111111111111111111111111111111111111";

describe("simulated transactions", () => {
  it("run the handlers whose filter matches, with the fields given", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({
      chains: {
        1: {
          startBlock: 0,
          endBlock: 10,
          simulate: [
            {
              transaction: { from: alice, to: token, input: "0xa9059cbb", value: 5n, status: 1 },
              block: { number: 3, timestamp: 1_700_000_003 },
            },
            // Reverted: the sender's handler runs, the status-filtered one doesn't.
            // Without a block of its own it lands on the previous item's block
            // number, with the default fields a simulated block gets.
            {
              transaction: { from: alice, to: token, input: "0xa9059cbb", status: 0, transactionIndex: 1 },
            },
          ],
        },
      },
    });
    t.expect((await indexer.Seen.getAll()).sort((a, b) => a.id.localeCompare(b.id))).toEqual([
      { id: "from-alice:3:0", from: alice, value: 5n, status: 1, timestamp: 1_700_000_003 },
      { id: "from-alice:3:1", from: alice, value: 0n, status: 0, timestamp: 0 },
      { id: "token-ok:3:0", from: alice, value: 0n, status: -1, timestamp: -1 },
    ]);
  });

  it("reports a transaction no handler matched as unrouted, beside one that ran", async (t) => {
    const indexer = createTestIndexer();
    const error = await indexer
      .process({
        chains: {
          1: {
            startBlock: 0,
            endBlock: 10,
            simulate: [
              { transaction: { from: alice, to: token }, block: { number: 3 } },
              { transaction: { from: bob, to: bob }, block: { number: 4 } },
            ],
          },
        },
      })
      .then(() => "no error", (error: Error) => error.message);

    t.expect(error).toContain("never reached a handler");
    t.expect(error).toContain("chain 1: 1");
  });

  it("rejects two transactions at the same coordinates", async (t) => {
    const indexer = createTestIndexer();
    const error = await indexer
      .process({
        chains: {
          1: {
            startBlock: 0,
            endBlock: 10,
            simulate: [
              { transaction: { from: alice, to: token }, block: { number: 3 } },
              // Same block as the item before, and the default index 0 again.
              { transaction: { from: alice, to: token } },
            ],
          },
        },
      })
      .then(() => "no error", (error: Error) => error.message);

    t.expect(error).toContain("both resolve to transaction 0 of block 3");
  });
});
`,
)
