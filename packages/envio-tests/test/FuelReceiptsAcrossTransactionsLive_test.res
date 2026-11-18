// Live test against fuel.hypersync.xyz, driven through the user API: real
// config, real handlers, the real source and the event store. In block
// 20,001,559 one contract emits a TransferOut, a Mint and a TransferOut in each
// of two transactions. Rows are keyed by block, receipt index and registration,
// so this pins that HyperFuel numbers receipts across the block, not per
// transaction: were it per transaction, the second transaction's receipts would
// share keys with the first's and be dropped as duplicates.

let block = 20001559

let _ = InternalTestIndexer.fromUserApi(
  ~files=dict{"abis/all-events-abi.json": FuelAbiFixtures.allEvents},
  ~configYaml=`
name: fuel-receipts-across-transactions-live
ecosystem: fuel
chains:
  - id: 9889
    start_block: ${block->Int.toString}
    end_block: ${block->Int.toString}
    contracts:
      - name: Token
        address: 0xd47730552bc68a09e2cb81fefc8f678426cbd4f95276a9011f6fc529d88e2004
        abi_file_path: abis/all-events-abi.json
        events:
          - name: Mint
          - name: Transfer
`,
  ~schema=`
type Receipt {
  id: ID!
  event: String!
  txId: String!
  amount: BigInt!
}
`,
  ~handlers=`
import { indexer } from "envio";

for (const event of ["Mint", "Transfer"] as const) {
  indexer.onEvent({ contract: "Token", event }, async ({ event: e, context }) => {
    context.Receipt.set({
      id: String(e.logIndex),
      event,
      txId: e.transaction.id,
      amount: e.params.amount,
    });
  });
}
`,
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("Fuel receipts across transactions (live)", () => {
  it(
    "hands handlers every receipt of a contract that emits in two transactions of one block",
    async (t) => {
      const indexer = createTestIndexer();
      await indexer.process({ chains: { 9889: { startBlock: ${block->Int.toString}, endBlock: ${block->Int.toString} } } });

      const receipts = await indexer.Receipt.getAll();
      const first = "0x1d84e6a8490832ea821d83816182afdd1ecca7c9e533a356644f52352ab86e09";
      const second = "0x0b58d2458779d8d6c291f3ef5ce0f5744b740b43b47c28507626482fe92acc94";
      t.expect(
        receipts
          .sort((a, b) => Number(a.id) - Number(b.id))
          .map((receipt) => [Number(receipt.id), receipt.event, receipt.txId, receipt.amount]),
      ).toEqual([
        [1, "Transfer", first, 900000n],
        [2, "Mint", first, 2n],
        [3, "Transfer", first, 2n],
        [9, "Transfer", second, 900000n],
        [10, "Mint", second, 2n],
        [11, "Transfer", second, 2n],
      ]);
    },
    300_000,
  );
});
`,
)
