// A pinned process() range starting above a contract's start_block: the
// contract simply has no events before the pinned start.
//
// https://github.com/enviodev/hyperindex/issues/1656
let _ = InternalTestIndexer.fromUserApi(
  ~configYaml=`
name: test-indexer-pinned-range
contracts:
  - name: Ledger
    events:
      - event: Transfer(address indexed from, address indexed to, uint256 amount)
  - name: Router
    events:
      - event: Zapped(address indexed sender, uint256 amount)
chains:
  - id: 1
    start_block: 100
    contracts:
      - name: Ledger
        start_block: 100
        address: "0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3"
      - name: Router
        start_block: 5000
        address: "0xa2F6E6029638cCb484A2ccb6414499aD3e825CaC"
`,
  ~schema=`
type Seen {
  id: ID!
}

type Tick {
  id: ID!
}
`,
  ~handlers=`
import { indexer } from "envio";

indexer.onEvent({ contract: "Ledger", event: "Transfer" }, async ({ event, context }) => {
  context.Seen.set({ id: \`ledger-\${event.block.number}\` });
});

indexer.onEvent({ contract: "Router", event: "Zapped" }, async ({ event, context }) => {
  context.Seen.set({ id: \`router-\${event.block.number}\` });
});

indexer.onBlock(
  { name: "ticks", where: () => ({ block: { number: { _every: 100 } } }) },
  async ({ block, context }) => {
    context.Tick.set({ id: \`\${block.number}\` });
  },
);
`,
  ~test=`
import { describe, it, expect } from "vitest";
import { createTestIndexer } from "envio";

const ledger = "0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3" as const;
const router = "0xa2F6E6029638cCb484A2ccb6414499aD3e825CaC" as const;
const owner = "0x3333333333333333333333333333333333333333" as const;
const zero = "0x0000000000000000000000000000000000000000" as const;

const ledgerTransfer = (blockNumber: number) => ({
  contract: "Ledger",
  event: "Transfer",
  params: { from: zero, to: owner, amount: 1n },
  srcAddress: ledger,
  block: { number: blockNumber },
} as const);

const routerZap = (blockNumber: number) => ({
  contract: "Router",
  event: "Zapped",
  params: { sender: owner, amount: 1n },
  srcAddress: router,
  block: { number: blockNumber },
} as const);

describe("createTestIndexer pinned range", () => {
  it("processes a range starting above a contract start_block", async () => {
    const indexer = createTestIndexer();
    await indexer.process({
      chains: {
        1: {
          startBlock: 1000,
          endBlock: 2000,
          simulate: [ledgerTransfer(1000), ledgerTransfer(1500)],
        },
      },
    });
    await indexer.process({
      chains: {
        1: {
          startBlock: 6000,
          endBlock: 7000,
          simulate: [ledgerTransfer(6000), routerZap(6500)],
        },
      },
    });
    expect((await indexer.Seen.getAll()).map((seen) => seen.id).sort()).toEqual([
      "ledger-1000",
      "ledger-1500",
      "ledger-6000",
      "router-6500",
    ]);
  });

  // The interval counts from the chain's start block, as it does when the
  // indexer runs against a real chain, not from the pinned start.
  it("keeps onBlock intervals aligned to the chain start block", async () => {
    const indexer = createTestIndexer();
    await indexer.process({ chains: { 1: { startBlock: 1050, endBlock: 1250 } } });
    expect((await indexer.Tick.getAll()).map((tick) => tick.id).sort()).toEqual([
      "1100",
      "1200",
    ]);
  });
});
`,
)
