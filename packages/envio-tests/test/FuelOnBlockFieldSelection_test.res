// Fuel block handlers get the block height alone: they can't select block
// fields, so a `fields` option fails type-checking and registration.
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
}
`,
  ~handlers=`
import { indexer } from "envio";

indexer.onBlock({ name: "blocks" }, async ({ block, context }) => {
  // @ts-expect-error - a Fuel block handler gets the height alone
  const _time: number = block.time;
  context.FuelBlock.set({ id: \`\${block.height}\` });
});
`,
  ~test=`
import { describe, it } from "vitest";
import { indexer } from "envio";

describe("Fuel onBlock field selection", () => {
  it("rejects a fields option", (t) => {
    t.expect(() =>
      indexer.onBlock(
        // @ts-expect-error - Fuel block handlers take no fields option
        { name: "bad", fields: { block: ["time"] } },
        async () => {},
      ),
    ).toThrowError('Fuel block handlers can\\'t select block fields. Remove the fields option of \`indexer.onBlock("bad")\`.');
  });
});
`,
)
