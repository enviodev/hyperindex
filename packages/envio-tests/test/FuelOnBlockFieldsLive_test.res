// Live test against fuel-testnet.hypersync.xyz, driven through the user API.
// The expected fields were read from the Fuel testnet GraphQL API, its TAI64
// times converted to Unix seconds. `sparse` runs every 5000 blocks, which the
// source reads one block at a time; once `dense` starts within 1000 blocks,
// the page reads the range.

let _apiToken =
  Env.envioApiToken->Option.getOrThrow(
    ~message="ENVIO_API_TOKEN env var must be set to run the live Fuel onBlock fields test",
  )

let _ = InternalTestIndexer.fromUserApi(
  ~configYaml=`
name: fuel-onblock-fields-live
ecosystem: fuel
chains:
  - id: 0
    start_block: 22158283
    end_block: 22168500
`,
  ~schema=`
type SeenBlock {
  id: ID!
  blockId: String!
  time: Int!
}
`,
  ~handlers=`
import { indexer, type FuelOnBlockHandler } from "envio";

const fields = { block: ["id", "time"] } as const;

const record =
  (name: string): FuelOnBlockHandler<typeof fields> =>
  async ({ block, context }) => {
    context.SeenBlock.set({ id: \`\${name}:\${block.height}\`, blockId: block.id, time: block.time });
  };

indexer.onBlock(
  {
    name: "sparse",
    where: () => ({ block: { height: { _gte: 22158283, _every: 5000 } } }),
    fields,
  },
  record("sparse"),
);

indexer.onBlock(
  {
    name: "dense",
    where: () => ({ block: { height: { _gte: 22163000, _lte: 22163002 } } }),
    fields,
  },
  record("dense"),
);
`,
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("onBlock fields over live HyperFuel", () => {
  it("hands each handler its block's fields", { timeout: 60_000 }, async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({ chains: { 0: { startBlock: 22158283, endBlock: 22168500 } } });

    t.expect(
      (await indexer.SeenBlock.getAll()).sort((a, b) => a.id.localeCompare(b.id)),
    ).toEqual([
      { id: "dense:22163000", blockId: "0x8961526ef4b312439cf3151db26000e7cb798f42abe8b96f7363cca5ae195fd9", time: 1738237399 },
      { id: "dense:22163001", blockId: "0x3e13c3d7a598af7ba6d5689ffaa6503398474c28bbb8af6ab5d3c1da61ff2bcd", time: 1738237400 },
      { id: "dense:22163002", blockId: "0xde7150578d92241e3fe9df8e3e81f31efef9418870c4aa70c3a53a6e31dc2405", time: 1738237401 },
      { id: "sparse:22158283", blockId: "0xd0ee28d97c6e87ed3956c84f7692e9eed8167f1256a934d3ee7289fdf965a727", time: 1738232647 },
      { id: "sparse:22163283", blockId: "0xf8300efe0c8d1372c5cf357c9e7520a3863ea9b4e5bd6412487c5901bad312e1", time: 1738237685 },
      { id: "sparse:22168283", blockId: "0xf6e04dee3e9351db8a02892e7f268a639e333cb221b337263059f9fea87b4449", time: 1738242725 },
    ]);
  });
});
`,
)
