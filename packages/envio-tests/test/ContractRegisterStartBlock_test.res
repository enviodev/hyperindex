// A `contractRegister` held back by `where.block.number._gte`, alongside an
// unrestricted `onEvent` for the same event. The two don't merge (their
// resolved `where`s differ), so the handler keeps the contract's address gate
// open from the chain start while the register itself must still ignore
// everything before its own block — otherwise it adds dynamic contracts the
// user asked it not to.
let _ = InternalTestIndexer.fromUserApi(
  ~configYaml=`
name: contract-register-start-block
contracts:
  - name: NftFactory
    events:
      - event: SimpleNftCreated(string name, address contractAddress)
  - name: SimpleNft
    events:
      - event: Transfer(address indexed from, address indexed to, uint256 tokenId)
chains:
  - id: 1
    start_block: 0
    contracts:
      - name: NftFactory
        address: "0xa2F6E6029638cCb484A2ccb6414499aD3e825CaC"
      - name: SimpleNft
`,
  ~schema=`
type Collection {
  id: ID!
  name: String!
}

type Token {
  id: ID!
  collection: String!
}
`,
  ~handlers=`
import { indexer } from "envio";

indexer.contractRegister(
  { contract: "NftFactory", event: "SimpleNftCreated", where: { block: { number: { _gte: 100 } } } },
  async ({ event, context }) => {
    context.chain.SimpleNft.add(event.params.contractAddress);
  },
);

indexer.onEvent({ contract: "NftFactory", event: "SimpleNftCreated" }, async ({ event, context }) => {
  context.Collection.set({ id: event.params.contractAddress, name: event.params.name });
});

indexer.onEvent({ contract: "SimpleNft", event: "Transfer" }, async ({ event, context }) => {
  context.Token.set({
    id: \`\${event.srcAddress}-\${event.params.tokenId}\`,
    collection: event.srcAddress,
  });
});
`,
  ~test=`
import { describe, it, expect } from "vitest";
import { createTestIndexer } from "envio";

const factory = "0xa2F6E6029638cCb484A2ccb6414499aD3e825CaC" as const;
const early = "0x1111111111111111111111111111111111111111" as const;
const late = "0x2222222222222222222222222222222222222222" as const;
const owner = "0x3333333333333333333333333333333333333333" as const;
const zero = "0x0000000000000000000000000000000000000000" as const;

const createNft = (contractAddress: typeof early | typeof late, blockNumber: number) => ({
  contract: "NftFactory",
  event: "SimpleNftCreated",
  params: { name: contractAddress, contractAddress },
  srcAddress: factory,
  block: { number: blockNumber },
} as const);

const transfer = (srcAddress: typeof early | typeof late, blockNumber: number) => ({
  contract: "SimpleNft",
  event: "Transfer",
  params: { from: zero, to: owner, tokenId: 1n },
  srcAddress,
  block: { number: blockNumber },
} as const);

const messageOf = async (run: () => Promise<unknown>): Promise<string | undefined> => {
  try {
    await run();
    return undefined;
  } catch (error) {
    return (error as Error).message;
  }
};

describe("contractRegister with its own startBlock", () => {
  // Both factory events reach the unrestricted handler, but only the one at or
  // after block 100 registers its address — so the late contract's transfer
  // routes, and the early one's, simulated well after both, never reaches a
  // handler at all.
  it("registers only from its own start block, while the handler sees every block", async (t) => {
    const indexer = createTestIndexer();
    const message = await messageOf(() =>
      indexer.process({
        chains: {
          1: {
            startBlock: 0,
            endBlock: 300,
            simulate: [
              createNft(early, 50),
              createNft(late, 150),
              transfer(late, 160),
              transfer(early, 200),
            ],
          },
        },
      }),
    );

    t.expect({
      collections: (await indexer.Collection.getAll()).map((c) => c.id).sort(),
      tokens: (await indexer.Token.getAll()).map((token) => token.collection).sort(),
      unrouted: message?.includes("1 item you passed to simulate never reached a handler"),
    }).toEqual({ collections: [early, late].sort(), tokens: [late], unrouted: true });
  });
});
`,
)
