// `start_block: latest` in config.yaml: the test indexer has no real chain to
// resolve "latest" against, so the chain's start block stays 0 — any explicit
// startBlock a test passes to process() is accepted, an onBlock handler
// registers against it without complaint, and both `indexer.chains[N]`
// surfaces (the exported indexer read from a handler, and the test indexer's
// own) agree on 0.
let _ = InternalTestIndexer.fromUserApi(
  ~configYaml=`
name: start-block-latest-test-indexer
contracts:
  - name: NftFactory
    events:
      - event: SimpleNftCreated(string name, address contractAddress)
chains:
  - id: 1
    start_block: latest
    contracts:
      - name: NftFactory
        address: "0xa2F6E6029638cCb484A2ccb6414499aD3e825CaC"
`,
  ~schema=`
type Seen {
  id: ID!
  block: Int!
  chainStartBlock: Int!
}
`,
  ~handlers=`
import { indexer } from "envio";

indexer.onEvent({ contract: "NftFactory", event: "SimpleNftCreated" }, async ({ event, context }) => {
  context.Seen.set({
    id: \`\${event.block.number}\`,
    block: event.block.number,
    chainStartBlock: indexer.chains[1].startBlock,
  });
});

indexer.onBlock({ name: "blocks", where: ({ chain }) => chain.id === 1 }, async () => {});
`,
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

const factory = "0xa2F6E6029638cCb484A2ccb6414499aD3e825CaC" as const;

const createNft = (blockNumber: number) => ({
  contract: "NftFactory",
  event: "SimpleNftCreated",
  params: { name: "n", contractAddress: factory },
  srcAddress: factory,
  block: { number: blockNumber },
} as const);

describe("start_block: latest in the test indexer", () => {
  it("reports 0 for a chain's unresolved start block", (t) => {
    const indexer = createTestIndexer();
    t.expect(indexer.chains[1].startBlock).toBe(0);
  });

  it("accepts any explicit startBlock and shows handlers the same 0", async (t) => {
    const indexer = createTestIndexer();
    // Would throw "startBlock is less than config.startBlock" if the test
    // indexer compared against a real (non-zero) resolved value.
    await indexer.process({
      chains: { 1: { startBlock: 500, endBlock: 600, simulate: [createNft(550)] } },
    });

    t.expect(await indexer.Seen.getAll()).toEqual([{ id: "550", block: 550, chainStartBlock: 0 }]);
  });
});
`,
)
