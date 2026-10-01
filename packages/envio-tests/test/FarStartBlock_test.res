// Contracts that start far past the chain's start block, in every shape a
// config can express, through the real fetch scheduler. What the user means by
// each is the same: events from the start block on are indexed, and the
// contracts that do start at the chain start are unaffected. (That events before
// a start block are dropped is RegistrationStartBlock_test's.)
// A chain that stops asking for blocks below its head fails the run as a stall
// instead of the test's own timeout.
//
// https://github.com/enviodev/hyperindex/issues/1650
let _ = InternalTestIndexer.fromUserApi(
  ~configYaml=`
name: far-start-block
contracts:
  - name: Ledger
    events:
      - event: Transfer(address indexed from, address indexed to, uint256 amount)
  - name: Router
    events:
      - event: Zapped(address indexed sender, uint256 amount)
  - name: Token
    events:
      - event: Transfer(address indexed from, address indexed to, uint256 value)
chains:
  - id: 1
    start_block: 0
    contracts:
      - name: Ledger
        address: "0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3"
      - name: Router
        start_block: 50000
        address: "0xa2F6E6029638cCb484A2ccb6414499aD3e825CaC"
      - name: Token
        start_block: 50000
`,
  ~schema=`
type Seen {
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

indexer.onEvent(
  { contract: "Token", event: "Transfer", wildcard: true },
  async ({ event, context }) => {
    context.Seen.set({ id: \`token-\${event.block.number}\` });
  },
);
`,
  ~test=`
import { describe, it, expect } from "vitest";
import { createTestIndexer } from "envio";

const ledger = "0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3" as const;
const router = "0xa2F6E6029638cCb484A2ccb6414499aD3e825CaC" as const;
const token = "0x1111111111111111111111111111111111111111" as const;
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

const tokenTransfer = (blockNumber: number) => ({
  contract: "Token",
  event: "Transfer",
  params: { from: zero, to: owner, value: 1n },
  srcAddress: token,
  block: { number: blockNumber },
} as const);

describe("contracts starting far past the chain start", () => {
  // The wildcard's start block is far past the chain start, so its partition
  // can't fall inside the first queries' range. The chain-start contract still
  // has to be fetched and processed all the way up, and every contract from
  // its own start block on.
  it("indexes every contract from its own start block", async () => {
    const indexer = createTestIndexer();
    await indexer.process({
      chains: {
        1: {
          startBlock: 0,
          endBlock: 100_000,
          simulate: [
            ledgerTransfer(10),
            ledgerTransfer(30_000),
            tokenTransfer(60_000),
            routerZap(60_001),
            ledgerTransfer(90_000),
          ],
        },
      },
    });
    expect((await indexer.Seen.getAll()).map((seen) => seen.id).sort()).toEqual([
      "ledger-10",
      "ledger-30000",
      "ledger-90000",
      "router-60001",
      "token-60000",
    ]);
  });

  // Nothing at all before the later contracts start: the chain-start contract
  // alone has to carry the chain past their start block.
  it("reaches the later start blocks with no events on the way", async () => {
    const indexer = createTestIndexer();
    await indexer.process({
      chains: {
        1: {
          startBlock: 0,
          endBlock: 100_000,
          simulate: [tokenTransfer(70_000), routerZap(70_001)],
        },
      },
    });
    expect((await indexer.Seen.getAll()).map((seen) => seen.id).sort()).toEqual([
      "router-70001",
      "token-70000",
    ]);
  });

  // The run ends before the later contracts begin: it completes with only the
  // chain-start contract's events rather than waiting for blocks that never
  // come.
  it("completes a run that ends before the later start blocks", async () => {
    const indexer = createTestIndexer();
    await indexer.process({
      chains: {
        1: {
          startBlock: 0,
          endBlock: 40_000,
          simulate: [ledgerTransfer(10), ledgerTransfer(30_000)],
        },
      },
    });
    expect((await indexer.Seen.getAll()).map((seen) => seen.id).sort()).toEqual([
      "ledger-10",
      "ledger-30000",
    ]);
  });
});
`,
)
