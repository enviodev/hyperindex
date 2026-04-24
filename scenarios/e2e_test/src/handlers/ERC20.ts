import { indexer } from "envio";

// Verify that indexer.chains reads endBlock from the database, not from config.
// E2E_EXPECTED_END_BLOCK is always required so the check runs on every start.
if (process.env.E2E_EXPECTED_END_BLOCK === undefined) {
  throw new Error("E2E_EXPECTED_END_BLOCK environment variable is required");
}
const expected = Number(process.env.E2E_EXPECTED_END_BLOCK);
const actual = indexer.chains[1].endBlock;
if (actual !== expected) {
  throw new Error(
    `endBlock mismatch: expected ${expected} from DB but got ${actual} (config value leaked)`
  );
}

indexer.onEvent({ contract: "ERC20", event: "Transfer" }, async ({ event, context }) => {
  context.Transfer.set({
    id: `${event.chainId}-${event.block.number}-${event.logIndex}`,
    from: event.params.from,
    to: event.params.to,
    value: event.params.value,
    blockNumber: event.block.number,
    transactionHash: event.transaction.hash,
  });
});
