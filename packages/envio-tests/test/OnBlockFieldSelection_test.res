// Block handlers name the block fields they read with the same `fields` option
// `onEvent` takes. A selection beyond the block number is what makes a source
// fetch the block, so the test indexer reads it off a simulated header.

let _ = InternalTestIndexer.fromUserApi(
  ~configYaml=`
name: on-block-field-selection
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
type Header {
  id: ID!
  timestamp: Int!
  miner: String!
}

type Tick {
  id: ID!
}

type Transferred {
  id: ID!
}
`,
  ~handlers=`
import { indexer } from "envio";

indexer.onBlock(
  {
    name: "headers",
    where: () => ({ block: { number: { _gte: 2, _lte: 6, _every: 2 } } }),
    fields: { block: ["timestamp", "miner"] },
  },
  async ({ block, context }) => {
    context.Header.set({ id: \`\${block.number}\`, timestamp: block.timestamp, miner: block.miner });
  },
);

// Reads nothing but the number, so it needs no block from a source.
indexer.onBlock({ name: "ticks", where: () => ({ block: { number: { _lte: 3 } } }) }, async ({ block, context }) => {
  // @ts-expect-error - only the number is selected
  const _timestamp: number = block.timestamp;
  context.Tick.set({ id: \`\${block.number}\` });
});

indexer.onEvent({ contract: "Token", event: "Transfer" }, async ({ event, context }) => {
  context.Transferred.set({ id: \`\${event.block.number}\` });
});
`,
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer, indexer } from "envio";

const miner = "0x000000000000000000000000000000000000beef";

describe("onBlock field selection", () => {
  it("rejects a field the ecosystem's blocks don't have", (t) => {
    t.expect(() =>
      indexer.onBlock(
        { name: "bad", fields: { block: ["notAField" as never] } },
        async () => {},
      ),
    ).toThrowError(
      'Invalid "notAField" field in the fields.block option of \`indexer.onBlock("bad")\`. Valid block fields: "number", "timestamp", "hash", "parentHash", "nonce", "sha3Uncles", "logsBloom", "transactionsRoot", "stateRoot", "receiptsRoot", "miner", "difficulty", "totalDifficulty", "extraData", "size", "gasLimit", "gasUsed", "uncles", "baseFeePerGas", "blobGasUsed", "excessBlobGas", "parentBeaconBlockRoot", "withdrawalsRoot", "l1BlockNumber", "sendCount", "sendRoot", "mixHash".',
    );
  });

  it("rejects a misspelled selection key", (t) => {
    t.expect(() =>
      indexer.onBlock(
        { name: "bad", fields: { blocks: ["miner"] } as never },
        async () => {},
      ),
    ).toThrowError(
      'Invalid "blocks" key in the fields option of \`indexer.onBlock("bad")\`. Valid keys: "block".',
    );
  });

  // A block handler runs on no transaction, so it has none to select.
  it("rejects a transaction selection", (t) => {
    t.expect(() =>
      indexer.onBlock(
        { name: "bad", fields: { transaction: ["hash"] } as never },
        async () => {},
      ),
    ).toThrowError(
      'Invalid "transaction" key in the fields option of \`indexer.onBlock("bad")\`. Valid keys: "block".',
    );
  });

  it("hands the handler the selected fields of each block", async (t) => {
    const testIndexer = createTestIndexer();
    await testIndexer.process({
      chains: {
        1: {
          startBlock: 0,
          endBlock: 6,
          simulate: [
            { block: { number: 2, timestamp: 1_700_000_002, miner } },
            // An event's block is the block, for its handler and a block
            // handler alike.
            {
              contract: "Token",
              event: "Transfer",
              params: { from: miner, to: miner, value: 1n },
              block: { number: 4, timestamp: 1_700_000_004, miner },
            },
            { block: { number: 6, timestamp: 1_700_000_006, miner } },
          ],
        },
      },
    });
    t.expect({
      headers: (await testIndexer.Header.getAll()).sort((a, b) => a.timestamp - b.timestamp),
      ticks: (await testIndexer.Tick.getAll()).map((tick) => tick.id).sort(),
    }).toEqual({
      headers: [
        { id: "2", timestamp: 1_700_000_002, miner },
        { id: "4", timestamp: 1_700_000_004, miner },
        { id: "6", timestamp: 1_700_000_006, miner },
      ],
      ticks: ["0", "1", "2", "3"],
    });
  });

  // An item without a block of its own follows the one before it, whether
  // that was an event or a block given on its own.
  it("places an event after a standalone block on that block", async (t) => {
    const testIndexer = createTestIndexer();
    await testIndexer.process({
      chains: {
        1: {
          startBlock: 0,
          endBlock: 6,
          simulate: [
            { block: { number: 5, timestamp: 1_700_000_005, miner } },
            { contract: "Token", event: "Transfer", params: { from: miner, to: miner, value: 1n } },
          ],
        },
      },
    });
    t.expect((await testIndexer.Transferred.getAll()).map((transfer) => transfer.id)).toEqual(["5"]);
  });
});
`,
)
