// Live test against eth.hypersync.xyz, driven through the user API: real
// config, real handlers, the real source. The expected fields were read from a
// public Ethereum RPC, so they check the HyperSync path against an independent
// one. `sparse` runs every 2000 blocks, which the source reads one block at a
// time; once `dense` starts within 1000 blocks, the page reads the range.

let _apiToken =
  Env.envioApiToken->Option.getOrThrow(
    ~message="ENVIO_API_TOKEN env var must be set to run the live EVM onBlock fields test",
  )

let _ = InternalTestIndexer.fromUserApi(
  ~configYaml=`
name: evm-onblock-fields-live
chains:
  - id: 1
    start_block: 23500000
    end_block: 23506000
`,
  ~schema=`
type SeenBlock {
  id: ID!
  timestamp: Int!
  hash: String!
  miner: String!
  gasUsed: BigInt!
}
`,
  ~handlers=`
import { indexer, type EvmOnBlockHandler } from "envio";

const fields = { block: ["timestamp", "hash", "miner", "gasUsed"] } as const;

const record =
  (name: string): EvmOnBlockHandler<typeof fields> =>
  async ({ block, context }) => {
    context.SeenBlock.set({
      id: \`\${name}:\${block.number}\`,
      timestamp: block.timestamp,
      hash: block.hash,
      miner: block.miner.toLowerCase(),
      gasUsed: block.gasUsed,
    });
  };

indexer.onBlock(
  {
    name: "sparse",
    where: () => ({ block: { number: { _gte: 23500000, _every: 2000 } } }),
    fields,
  },
  record("sparse"),
);

indexer.onBlock(
  {
    name: "dense",
    where: () => ({ block: { number: { _gte: 23505000, _lte: 23505009, _every: 3 } } }),
    fields,
  },
  record("dense"),
);
`,
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("onBlock fields over live HyperSync", () => {
  it("hands each handler its block's fields", { timeout: 60_000 }, async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({ chains: { 1: { startBlock: 23500000, endBlock: 23506000 } } });

    t.expect(
      (await indexer.SeenBlock.getAll()).sort((a, b) => a.id.localeCompare(b.id)),
    ).toEqual([
      { id: "dense:23505000", timestamp: 1759587983, hash: "0x2875c1507646b4bf32737d4a4ec56ff0c6d34d97165675d2f65b4b509ceb4bd2", miner: "0xdadb0d80178819f2319190d340ce9a924f783711", gasUsed: 21393837n },
      { id: "dense:23505003", timestamp: 1759588019, hash: "0xef07cbfee44a0ee72fd945c8067c22cd8e8986ab6009ceed0ab24a5dba74d5a0", miner: "0xdadb0d80178819f2319190d340ce9a924f783711", gasUsed: 22203292n },
      { id: "dense:23505006", timestamp: 1759588055, hash: "0x1f2b06ad2e49ab95d9abacca2dca9286826bcc77b01355cd4c385b9c0246d5ab", miner: "0x4838b106fce9647bdf1e7877bf73ce8b0bad5f97", gasUsed: 20014372n },
      { id: "dense:23505009", timestamp: 1759588103, hash: "0x7faf318cc05548af204772d5b0ce8bd0929eadd357f54c71291a729b78d1cfcb", miner: "0xdadb0d80178819f2319190d340ce9a924f783711", gasUsed: 30387387n },
      { id: "sparse:23500000", timestamp: 1759527635, hash: "0xa8cfd32497fa9893700288c80b8f6240336addc415fd372d3d5340823a084b27", miner: "0x4838b106fce9647bdf1e7877bf73ce8b0bad5f97", gasUsed: 21364254n },
      { id: "sparse:23502000", timestamp: 1759551767, hash: "0x2ea9ca62252a2374318c0a01d0d73ccc5006ebfefd45d1b3ca2b12fb8e10999d", miner: "0x4838b106fce9647bdf1e7877bf73ce8b0bad5f97", gasUsed: 26253919n },
      { id: "sparse:23504000", timestamp: 1759575899, hash: "0x3f2cd56a0870262a39e7d32f579bdf15956095d3f2b2891d799e464218efc3ae", miner: "0x4838b106fce9647bdf1e7877bf73ce8b0bad5f97", gasUsed: 18502132n },
      { id: "sparse:23506000", timestamp: 1759600079, hash: "0xe5645cdced41677cda57c162274143a87dd5f241112f18e305f56a26748a83e8", miner: "0x18bb896994283bd9c16aa2072777a97c12f1b290", gasUsed: 44948695n },
    ]);
  });
});
`,
)
