// NftFactory.SimpleNftCreated's contractRegister adds the emitted
// `contractAddress` as a SimpleNft; SimpleNft.Transfer is a non-wildcard event
// for that dynamically-registered contract (SimpleNft has no configured
// address). Migrated from scenarios/test_codegen, which needed a codegen'd
// project to run the same cases.
//
// Note the `\${` escapes in the handler source: these are ReScript template
// strings, so an unescaped `${` would be interpolated before the TS ever sees it.
let _ = InternalTestIndexer.fromUserApi(
  ~configYaml=`
name: nft-factory
contracts:
  - name: NftFactory
    events:
      - event: SimpleNftCreated(string name, string symbol, uint256 maxSupply, address contractAddress)
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
type NftCollection {
  id: ID!
  contractAddress: String!
  name: String!
  symbol: String!
  maxSupply: BigInt!
}

type Token {
  id: ID!
  tokenId: BigInt!
  collection: String!
  owner: String!
}
`,
  ~handlers=`
import { indexer } from "envio";

indexer.contractRegister({ contract: "NftFactory", event: "SimpleNftCreated" }, async ({ event, context }) => {
  context.chain.SimpleNft.add(event.params.contractAddress);
});

indexer.onEvent({ contract: "NftFactory", event: "SimpleNftCreated" }, async ({ event, context }) => {
  context.NftCollection.set({
    id: event.params.contractAddress,
    contractAddress: event.params.contractAddress,
    name: event.params.name,
    symbol: event.params.symbol,
    maxSupply: event.params.maxSupply,
  });
});

indexer.onEvent({ contract: "SimpleNft", event: "Transfer" }, async ({ event, context }) => {
  context.Token.set({
    id: \`\${event.srcAddress}-\${event.params.tokenId}\`,
    tokenId: event.params.tokenId,
    collection: event.srcAddress,
    owner: event.params.to,
  });
});
`,
  ~test=`
import { describe, it, expect } from "vitest";
import { createTestIndexer, type Token, type NftCollection } from "envio";

const nftFactory = "0xa2F6E6029638cCb484A2ccb6414499aD3e825CaC" as const;
const newNft = "0x1111111111111111111111111111111111111111" as const;
const owner = "0x2222222222222222222222222222222222222222" as const;
const zero = "0x0000000000000000000000000000000000000000" as const;

const createNft = {
  contract: "NftFactory",
  event: "SimpleNftCreated",
  params: { name: "n", symbol: "s", maxSupply: 0n, contractAddress: newNft },
  srcAddress: nftFactory,
} as const;

const transferNft = {
  contract: "SimpleNft",
  event: "Transfer",
  params: { from: zero, to: owner, tokenId: 7n },
  srcAddress: newNft,
} as const;

const expectedToken: Token = {
  id: \`\${newNft}-7\`,
  tokenId: 7n,
  collection: newNft,
  owner,
};

const expectedCollection: NftCollection = {
  id: newNft,
  contractAddress: newNft,
  name: "n",
  symbol: "s",
  maxSupply: 0n,
};

const messageOf = async (run: () => Promise<unknown>): Promise<string | undefined> => {
  try {
    await run();
    return undefined;
  } catch (error) {
    return (error as Error).message;
  }
};

describe("simulate with dynamically registered addresses", () => {
  // A non-wildcard SimpleNft.Transfer for an address registered in an earlier
  // process() call routes to the handler unchanged.
  it("routes an event for a contract registered in an earlier process() call", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({ chains: { 1: { startBlock: 1, endBlock: 100, simulate: [createNft] } } });
    await indexer.process({ chains: { 1: { startBlock: 101, endBlock: 200, simulate: [transferNft] } } });

    t.expect(await indexer.Token.getAll()).toEqual([expectedToken]);
  });

  // The simulate path doesn't pre-check srcAddress against a static snapshot,
  // so a contract registered within the same call is accepted too.
  it("accepts an event for a contract registered in the same process() call", async (t) => {
    const indexer = createTestIndexer();
    const message = await messageOf(() =>
      indexer.process({ chains: { 1: { startBlock: 1, endBlock: 100, simulate: [createNft, transferNft] } } }),
    );

    t.expect(message).toBe(undefined);
  });

  // Regression: an explicit logIndex on the first item must not steal the auto
  // item's slot. [explicit 0, auto] resolves to 0 then 1, not two zeros.
  it("accepts an explicit logIndex followed by an auto-increment item", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({
      chains: { 1: { startBlock: 1, endBlock: 100, simulate: [{ ...createNft, logIndex: 0 }, transferNft] } },
    });

    t.expect(await indexer.Token.getAll()).toEqual([expectedToken]);
  });

  // Nothing registers newNft, so the address filter drops the Transfer and its
  // handler never runs. The run reports the dead input instead of passing.
  it("reports an item whose srcAddress is never indexed", async (t) => {
    const indexer = createTestIndexer();
    const message = await messageOf(() =>
      indexer.process({ chains: { 1: { startBlock: 1, endBlock: 100, simulate: [transferNft] } } }),
    );

    t.expect(message).toContain("1 item you passed to simulate never reached a handler");
  });

  // config.yaml stores NftFactory's address checksummed; a differently-cased
  // srcAddress must still route the non-wildcard event.
  it("routes an event whose srcAddress casing differs from the config", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({
      chains: {
        1: {
          startBlock: 1,
          endBlock: 100,
          simulate: [{ ...createNft, srcAddress: "0xa2f6e6029638ccb484a2ccb6414499ad3e825cac" }],
        },
      },
    });

    t.expect(await indexer.NftCollection.getAll()).toEqual([expectedCollection]);
  });

  // An invalid EIP-55 checksum is still a valid 20-byte address; normalization
  // recomputes the checksum rather than requiring a correct one.
  it("routes an event whose srcAddress has an invalid checksum casing", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({
      chains: {
        1: {
          startBlock: 1,
          endBlock: 100,
          simulate: [{ ...createNft, srcAddress: "0xA2F6E6029638CCB484A2CCB6414499AD3E825CAC" }],
        },
      },
    });

    t.expect(await indexer.NftCollection.getAll()).toEqual([expectedCollection]);
  });

  // Two items on the same (block, logIndex) is ambiguous — event ordering and
  // the dead-input tracker both key on it — so it's rejected at parse.
  it("rejects items that resolve to the same block and logIndex", async (t) => {
    const indexer = createTestIndexer();
    const message = await messageOf(() =>
      indexer.process({
        chains: {
          1: {
            startBlock: 1,
            endBlock: 100,
            simulate: [{ ...createNft, logIndex: 0 }, { ...transferNft, logIndex: 0 }],
          },
        },
      }),
    );

    t.expect(message).toBe(
      "simulate: items at index 0 and 1 on chain 1 both resolve to block 1, logIndex 0. " +
        "Give each item a distinct logIndex (or omit logIndex so they auto-increment).",
    );
  });
});
`,
)
