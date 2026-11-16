// Live test against fuel-testnet.hypersync.xyz, driven through the user API:
// real config, real handlers, the real source and routing. The AllEvents
// contract minted, transferred out to a wallet, transferred to a contract and
// burned across these two blocks, so this pins the params handlers receive for
// every non-LogData receipt kind the contract emits: Mint and Burn as
// `{subId, amount}`, Transfer as `{to, assetId, amount}` with a TransferOut's
// wallet recipient as `to`. No Call receipt exists for the contract.

let fromBlock = 22158288
let toBlock = 22158293

let _ = InternalTestIndexer.fromUserApi(
  ~files=dict{"abis/all-events-abi.json": FuelAbiFixtures.allEvents},
  ~configYaml=`
name: fuel-receipt-params-live
ecosystem: fuel
chains:
  - id: 0
    start_block: ${fromBlock->Int.toString}
    end_block: ${toBlock->Int.toString}
    contracts:
      - name: AllEvents
        address: 0xd298efffbf3cdf38b4b55ffe76a97a67b9146d7edd61b92cca730bd6e0eb415d
        abi_file_path: abis/all-events-abi.json
        events:
          - name: Mint
          - name: Burn
          - name: Transfer
`,
  ~schema=`
type Receipt {
  id: ID!
  event: String!
  params: String!
}
`,
  ~handlers=`
import { indexer } from "envio";

// Renders a JS value so every distinction a handler can observe survives:
// number vs bigint vs string, key order.
const show = (value: unknown): string =>
  typeof value === "bigint"
    ? \`\${value}n\`
    : typeof value === "object" && value !== null
      ? \`{\${Object.entries(value).map(([key, item]) => \`\${key}:\${show(item)}\`).join(",")}}\`
      : JSON.stringify(value);

for (const event of ["Mint", "Burn", "Transfer"] as const) {
  indexer.onEvent({ contract: "AllEvents", event }, async ({ event: e, context }) => {
    context.Receipt.set({ id: \`\${e.block.height}-\${e.logIndex}\`, event, params: show(e.params) });
  });
}
`,
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("Fuel receipt params (live)", () => {
  it(
    "hands handlers Mint, Burn and Transfer params",
    async (t) => {
      const indexer = createTestIndexer();
      await indexer.process({ chains: { 0: { startBlock: ${fromBlock->Int.toString}, endBlock: ${toBlock->Int.toString} } } });

      const receipts = await indexer.Receipt.getAll();
      t.expect(
        receipts
          .sort((a, b) => a.id.localeCompare(b.id))
          .map((receipt) => [receipt.id, receipt.event, receipt.params]),
      ).toEqual([
        [
          "22158288-1",
          "Mint",
          '{subId:"0x0000000000000000000000000000000000000000000000000000000000000000",amount:200n}',
        ],
        [
          "22158288-2",
          "Transfer",
          '{to:"0x2072fe0e4c1cf1fe7ba3c4569992908fe4d7aecc9655c9d0c4da9285ade32c5f",assetId:"0xfab15ce0df3096a5ad7bd1233fbc7598933b33485a535a4ee24582a98f00f0c7",amount:200n}',
        ],
        [
          "22158293-1",
          "Transfer",
          '{to:"0x2072fe0e4c1cf1fe7ba3c4569992908fe4d7aecc9655c9d0c4da9285ade32c5f",assetId:"0xf8f8b6283d7fa5b672b530cbb84fcccb4ff8dc40f8176ef4544ddb1f1952ad07",amount:99n}',
        ],
        [
          "22158293-2",
          "Transfer",
          '{to:"0xb9bc445e5696c966dcf7e5d1237bd03c04e3ba6929bdaedfeebc7aae784c3a0b",assetId:"0xf8f8b6283d7fa5b672b530cbb84fcccb4ff8dc40f8176ef4544ddb1f1952ad07",amount:1n}',
        ],
        [
          "22158293-3",
          "Burn",
          '{subId:"0x0000000000000000000000000000000000000000000000000000000000000000",amount:200n}',
        ],
      ]);
    },
    300_000,
  );
});
`,
)
