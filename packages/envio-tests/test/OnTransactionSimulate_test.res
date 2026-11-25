// Transaction handlers under `createTestIndexer()`: a simulated transaction is
// routed by the same matching a source's is, holding only the fields the test
// gave, and its handler gets an event handler's context, preload pass
// included. Simulated events place among the block's transactions by the
// index of the transaction they carry.

let _ = InternalTestIndexer.fromUserApi(
  ~configYaml=`
name: on-transaction-simulate
contracts:
  - name: Token
    events:
      - event: Transfer(address indexed from, address indexed to, uint256 value)
        field_selection:
          transaction_fields:
            - transactionIndex
chains:
  - id: 1
    start_block: 0
    contracts:
      - name: Token
        address: "0x3333333333333333333333333333333333333333"
`,
  ~schema=`
type Sequence {
  id: ID!
  calls: Int!
}

type Call {
  id: ID!
  name: String!
}

type Hashes {
  id: ID!
  blockHash: String!
}

type BlockNonce {
  id: ID!
  nonce: BigInt!
}

type Sent {
  id: ID!
  value: BigInt!
  input: String!
  miner: String!
  timestamp: Int!
  label: String!
}
`,
  ~handlers=`
import { indexer, createEffect, S } from "envio";

const alice = "0x1111111111111111111111111111111111111111";
const bob = "0x2222222222222222222222222222222222222222";

const label = createEffect(
  { name: "label", input: { address: S.string }, output: S.string, rateLimit: false, cache: false },
  async ({ input }) => (input.address === alice ? "alice" : "someone"),
);

const record = async (context: any, name: string) => {
  if (context.isPreload) {
    const preloads = ((globalThis as any).onTransactionPreloads ??= []);
    preloads.push(name);
    return;
  }
  const sequence = (await context.Sequence.get("calls")) ?? { id: "calls", calls: 0 };
  context.Sequence.set({ ...sequence, calls: sequence.calls + 1 });
  context.Call.set({ id: \`\${sequence.calls}\`, name });
};

indexer.onTransaction(
  {
    name: "from-alice",
    where: () => ({ transaction: { from: [alice] } }),
    fields: { transaction: ["hash", "transactionIndex", "from", "value", "input"], block: ["timestamp", "miner"] },
  },
  async ({ transaction, context }) => {
    await record(context, \`from-alice \${transaction.block.number}/\${transaction.transactionIndex}\`);
    if (!context.isPreload && transaction.value !== undefined) {
      context.Sent.set({
        id: transaction.hash,
        value: transaction.value,
        input: transaction.input,
        miner: transaction.block.miner,
        timestamp: transaction.block.timestamp,
        label: await context.effect(label, { address: transaction.from ?? "" }),
      });
    }
  },
);
indexer.onTransaction(
  { name: "to-bob", where: () => ({ transaction: { to: [bob] } }), fields: { transaction: ["transactionIndex"] } },
  async ({ transaction, context }) =>
    record(context, \`to-bob \${transaction.block.number}/\${transaction.transactionIndex}\`),
);
indexer.onTransaction(
  { name: "succeeded", where: () => ({ transaction: { status: [1] } }), fields: { transaction: ["transactionIndex"] } },
  async ({ transaction, context }) =>
    record(context, \`succeeded \${transaction.block.number}/\${transaction.transactionIndex}\`),
);
indexer.onTransaction(
  { name: "throws", where: () => ({ transaction: { from: ["0x00000000000000000000000000000000000000ff"] } }) },
  async ({ context }) => {
    if (!context.isPreload) throw new Error("Error from a transaction handler");
  },
);
indexer.onTransaction(
  {
    name: "hashes",
    where: () => ({ transaction: { from: ["0x00000000000000000000000000000000000000dd"] } }),
    fields: { transaction: ["hash"], block: ["hash"] },
  },
  async ({ transaction, context }) => {
    context.Hashes.set({ id: transaction.hash, blockHash: transaction.block.hash });
  },
);
indexer.onTransaction(
  {
    name: "block-nonces",
    where: () => ({ transaction: { from: ["0x00000000000000000000000000000000000000cc"] } }),
    fields: { block: ["nonce"] },
  },
  async ({ transaction, context }) => {
    context.BlockNonce.set({ id: \`\${transaction.block.number}\`, nonce: transaction.block.nonce ?? -1n });
  },
);
indexer.onEvent({ contract: "Token", event: "Transfer" }, async ({ event, context }) =>
  record(context, \`Transfer \${event.transaction.block.number}/\${event.logIndex}\`),
);
`,
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

const alice = "0x1111111111111111111111111111111111111111";
const bob = "0x2222222222222222222222222222222222222222";
const carol = "0x3333333333333333333333333333333333333333";
const miner = "0x000000000000000000000000000000000000beef";
const hash = "0x" + "ab".repeat(32);
const transferCall = "0xa9059cbb" + "00".repeat(32);

describe("onTransaction under simulate", () => {
  it("routes each simulated transaction and places events among them", async (t) => {
    (globalThis as any).onTransactionPreloads = [];
    const indexer = createTestIndexer();
    await indexer.process({
      chains: {
        1: {
          startBlock: 0,
          endBlock: 5,
          simulate: [
            {
              transaction: { hash, from: alice, to: bob, input: transferCall, value: 5n, status: 1 },
              block: { number: 3, timestamp: 1_700_000_003, miner },
            },
            // No status given: a simulated transaction succeeded.
            { transaction: { from: carol, to: bob, transactionIndex: 2 } },
            { transaction: { from: carol, to: bob, transactionIndex: 1 } },
            // An event of the transaction at index 1: it runs after that
            // transaction's handlers and before the next one's.
            {
              contract: "Token",
              event: "Transfer",
              params: { from: alice, to: bob, value: 1n },
              transaction: { transactionIndex: 1 },
            },
            // Takes the block's next free index, 3, and has no \`to\`.
            { transaction: { from: alice } },
          ],
        },
      },
    });
    t.expect({
      calls: (await indexer.Call.getAll())
        .sort((a, b) => Number(a.id) - Number(b.id))
        .map((call) => call.name),
      preloads: (globalThis as any).onTransactionPreloads,
      sent: await indexer.Sent.getAll(),
    }).toEqual({
      calls: [
        "from-alice 3/0",
        "to-bob 3/0",
        "succeeded 3/0",
        "to-bob 3/1",
        "succeeded 3/1",
        "Transfer 3/0",
        "to-bob 3/2",
        "succeeded 3/2",
        "from-alice 3/3",
        "succeeded 3/3",
      ],
      preloads: [
        "from-alice 3/0",
        "to-bob 3/0",
        "succeeded 3/0",
        "to-bob 3/1",
        "succeeded 3/1",
        "Transfer 3/0",
        "to-bob 3/2",
        "succeeded 3/2",
        "from-alice 3/3",
        "succeeded 3/3",
      ],
      sent: [
        {
          id: hash,
          value: 5n,
          input: transferCall,
          // Read back checksummed, as every address the buffer joins is.
          miner: "0x000000000000000000000000000000000000bEEF",
          timestamp: 1_700_000_003,
          label: "alice",
        },
      ],
    });
  });

  it("names the transaction handler that threw", async (t) => {
    const indexer = createTestIndexer();
    await t
      .expect(
        indexer.process({
          chains: {
            1: {
              startBlock: 0,
              endBlock: 5,
              simulate: [{ transaction: { from: "0x00000000000000000000000000000000000000ff" } }],
            },
          },
        }),
      )
      .rejects.toThrow("Error from a transaction handler");
  });

  // A handler always reads its transaction's and block's hashes, so a test
  // leaving them out gets ones made from where the transaction sits.
  it("fills the hashes a test leaves out", async (t) => {
    const indexer = createTestIndexer();
    const dave = "0x00000000000000000000000000000000000000dd";
    await indexer.process({
      chains: {
        1: {
          startBlock: 0,
          endBlock: 5,
          simulate: [
            { transaction: { from: dave }, block: { number: 4 } },
            { transaction: { from: dave, transactionIndex: 7 } },
          ],
        },
      },
    });
    const word = (n: number) => n.toString(16).padStart(64, "0");
    t.expect((await indexer.Hashes.getAll()).sort((a, b) => a.id.localeCompare(b.id))).toEqual([
      { id: "0x" + word(4).slice(32) + word(0).slice(32), blockHash: "0x" + word(4) },
      { id: "0x" + word(4).slice(32) + word(7).slice(32), blockHash: "0x" + word(4) },
    ]);
  });

  // A block nonce is 8 bytes of data, which a test gives as a bigint.
  it("reads back the block nonce a test gives", async (t) => {
    const indexer = createTestIndexer();
    const cc = "0x00000000000000000000000000000000000000cc";
    await indexer.process({
      chains: {
        1: {
          startBlock: 0,
          endBlock: 5,
          simulate: [
            { transaction: { from: cc }, block: { number: 1, nonce: 0n } },
            { transaction: { from: cc }, block: { number: 2, nonce: 42n } },
          ],
        },
      },
    });
    t.expect((await indexer.BlockNonce.getAll()).sort((a, b) => a.id.localeCompare(b.id))).toEqual([
      { id: "1", nonce: 0n },
      { id: "2", nonce: 42n },
    ]);
  });

  it("refuses a transactionIndex that isn't a non-negative integer", async (t) => {
    const indexer = createTestIndexer();
    await t
      .expect(
        indexer.process({
          chains: {
            1: { startBlock: 0, endBlock: 5, simulate: [{ transaction: { from: alice, transactionIndex: -1 } }] },
          },
        }),
      )
      .rejects.toThrow(
        "simulate: transaction at index 0 on chain 1: transactionIndex must be a non-negative integer, got -1",
      );
  });

  // A transaction no filter matches would otherwise let a test pass without
  // running anything, as an event no handler runs on would.
  it("fails the run over a transaction no handler ran on", async (t) => {
    const indexer = createTestIndexer();
    await t
      .expect(
        indexer.process({
          chains: {
            1: {
              startBlock: 0,
              endBlock: 5,
              simulate: [
                { transaction: { from: alice } },
                // Reverted: only a filter listing \`status: [0]\` runs on it.
                { transaction: { from: carol, status: 0 } },
                { transaction: { from: alice } },
              ],
            },
          },
        }),
      )
      .rejects.toThrow(
        "simulate: 1 item you passed to simulate never reached a handler, so nothing ran for them. Each was filtered out before the handler, usually by a non-wildcard srcAddress that isn't indexed for the contract, a where/block filter that excluded the event, or, for a transaction, no onTransaction filter matching the fields it gives. Unrouted items, by index in each chain's simulate array:\\n  - chain 1: 1",
      );
  });

  it("names an unrouted event by its index in the simulate array, past a transaction", async (t) => {
    const indexer = createTestIndexer();
    await t
      .expect(
        indexer.process({
          chains: {
            1: {
              startBlock: 0,
              endBlock: 5,
              simulate: [
                { transaction: { from: alice } },
                {
                  contract: "Token",
                  event: "Transfer",
                  srcAddress: "0x00000000000000000000000000000000000000ab",
                  params: { from: alice, to: bob, value: 1n },
                },
              ],
            },
          },
        }),
      )
      .rejects.toThrow("Unrouted items, by index in each chain's simulate array:\\n  - chain 1: 1");
  });

  it("refuses a transaction field it doesn't know", async (t) => {
    const indexer = createTestIndexer();
    await t
      .expect(
        indexer.process({
          chains: {
            1: { startBlock: 0, endBlock: 5, simulate: [{ transaction: { form: alice } as any }] },
          },
        }),
      )
      .rejects.toThrow('simulate: transaction at index 0 on chain 1: unknown transaction field "form"');
  });
});
`,
)
