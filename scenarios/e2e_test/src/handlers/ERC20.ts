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
  const id = `${event.chainId}-${event.block.number}-${event.logIndex}`;

  context.Transfer.set({
    id,
    from: event.params.from,
    to: event.params.to,
    value: event.params.value,
    blockNumber: event.block.number,
    transactionHash: event.transaction.hash,
  });

  // Per-entity storage override: only Postgres receives this row
  // (declared in schema.graphql via @storage(postgres: true)).
  context.TransferPgOnly.set({
    id,
    from: event.params.from,
    value: event.params.value,
  });

  // Mirror override: only ClickHouse receives this row.
  context.TransferChOnly.set({
    id,
    from: event.params.from,
    value: event.params.value,
  });
});
