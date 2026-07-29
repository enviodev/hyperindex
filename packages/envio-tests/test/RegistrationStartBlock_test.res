// A registration's own start block — its contract's configured `start_block`,
// overridden by `where.block.number._gte` — is enforced per registration, while
// the chain's address gate is only contract-wide. So an unrestricted sibling
// keeps that gate open from the chain start, and each scenario here turns on the
// two disagreeing.
let _ = InternalTestIndexer.fromUserApi(
  ~configYaml=`
name: registration-start-block
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
type Seen {
  id: ID!
  handler: String!
  block: Int!
}

type Collection {
  id: ID!
}

type Token {
  id: ID!
}
`,
  ~handlers=`
import { indexer } from "envio";

// Two handlers for one event: unrestricted, and held back to block 100.
indexer.onEvent({ contract: "NftFactory", event: "SimpleNftCreated" }, async ({ event, context }) => {
  context.Seen.set({ id: \`all-\${event.block.number}\`, handler: "all", block: event.block.number });
  context.Collection.set({ id: event.params.contractAddress });
});

indexer.onEvent(
  { contract: "NftFactory", event: "SimpleNftCreated", where: { block: { number: { _gte: 100 } } } },
  async ({ event, context }) => {
    context.Seen.set({
      id: \`gte100-\${event.block.number}\`,
      handler: "gte100",
      block: event.block.number,
    });
  },
);

// The same pair again, wildcard this time: an address-free registration has no
// addresses to derive a first block from, so only its start block holds it back.
indexer.onEvent(
  { contract: "SimpleNft", event: "Transfer", wildcard: true },
  async ({ event, context }) => {
    context.Seen.set({
      id: \`wildcardAll-\${event.block.number}\`,
      handler: "wildcardAll",
      block: event.block.number,
    });
  },
);

indexer.onEvent(
  {
    contract: "SimpleNft",
    event: "Transfer",
    wildcard: true,
    where: { block: { number: { _gte: 100 } } },
  },
  async ({ event, context }) => {
    context.Seen.set({
      id: \`wildcardGte100-\${event.block.number}\`,
      handler: "wildcardGte100",
      block: event.block.number,
    });
  },
);

// Non-wildcard, so it only ever sees a registered address — which is what makes
// it evidence of what the contractRegister below did.
indexer.onEvent({ contract: "SimpleNft", event: "Transfer" }, async ({ event, context }) => {
  context.Token.set({ id: event.srcAddress });
});

indexer.contractRegister(
  { contract: "NftFactory", event: "SimpleNftCreated", where: { block: { number: { _gte: 100 } } } },
  async ({ event, context }) => {
    context.chain.SimpleNft.add(event.params.contractAddress);
  },
);
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

const seenBy = async (indexer: ReturnType<typeof createTestIndexer>, handler: string) =>
  (await indexer.Seen.getAll())
    .filter((seen) => seen.handler === handler)
    .map((seen) => seen.block)
    .sort((a, b) => a - b);

describe("a registration's own start block", () => {
  // The address gate has to stay open at block 50 for the unrestricted handler,
  // so only the per-registration gate keeps the filtered one out.
  it("holds back one handler while its unrestricted sibling sees every block", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({
      chains: {
        1: { startBlock: 0, endBlock: 300, simulate: [createNft(early, 50), createNft(late, 150)] },
      },
    });

    t.expect({
      all: await seenBy(indexer, "all"),
      gte100: await seenBy(indexer, "gte100"),
    }).toEqual({ all: [50, 150], gte100: [150] });
  });

  // No address is registered here at all, so both wildcard handlers take these
  // transfers on merit and only the start block separates them.
  it("holds back a wildcard registration with no addresses behind it", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({
      chains: {
        1: { startBlock: 0, endBlock: 300, simulate: [transfer(early, 50), transfer(early, 150)] },
      },
    });

    t.expect({
      wildcardAll: await seenBy(indexer, "wildcardAll"),
      wildcardGte100: await seenBy(indexer, "wildcardGte100"),
    }).toEqual({ wildcardAll: [50, 150], wildcardGte100: [150] });
  });

  // Both factory events reach the unrestricted handler, but only the one at or
  // after block 100 registers its address — so only that contract's transfer
  // reaches the non-wildcard handler.
  it("registers a dynamic contract only from the register's own start block", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({
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
    });

    t.expect({
      collections: (await indexer.Collection.getAll()).map((c) => c.id).sort(),
      // The wildcard handlers take both transfers whatever their emitter, so
      // they say nothing about registration; the non-wildcard one does.
      tokens: (await indexer.Token.getAll()).map((token) => token.id),
    }).toEqual({ collections: [early, late].sort(), tokens: [late] });
  });
});
`,
)
