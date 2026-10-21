// Fuel block handlers select block fields the way EVM ones do.
let _ = InternalTestIndexer.fromUserApi(
  ~files=dict{"abis/greeter-abi.json": FuelAbiFixtures.greeter},
  ~configYaml=`
name: fuel-onblock-fields
ecosystem: fuel
chains:
  - id: 0
    start_block: 0
    contracts:
      - name: Greeter
        address: 0xb9bc445e5696c966dcf7e5d1237bd03c04e3ba6929bdaedfeebc7aae784c3a0b
        abi_file_path: abis/greeter-abi.json
        events:
          - name: NewGreeting
`,
  ~schema=`
type FuelBlock {
  id: ID!
  time: Int!
  blockId: String!
}
`,
  ~handlers=`
import { indexer } from "envio";

indexer.onBlock(
  { name: "blocks", where: () => ({ block: { height: { _every: 2 } } }), fields: { block: ["time", "id"] } },
  async ({ block, context }) => {
    context.FuelBlock.set({ id: \`\${block.height}\`, time: block.time, blockId: block.id });
  },
);
`,
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("Fuel onBlock field selection", () => {
  it("hands the handler the selected fields of each block", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({
      chains: {
        0: {
          startBlock: 0,
          endBlock: 2,
          simulate: [{ block: { height: 2, time: 1_700_000_002, id: "0x02" } }],
        },
      },
    });
    t.expect(
      (await indexer.FuelBlock.getAll()).sort((a, b) => a.time - b.time),
    ).toEqual([
      { id: "0", time: 0, blockId: "" },
      { id: "2", time: 1_700_000_002, blockId: "0x02" },
    ]);
  });
});
`,
)
