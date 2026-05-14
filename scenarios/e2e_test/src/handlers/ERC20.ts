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

// Asserts that an error thrown by a context.<entity>.<op>() call carries
// the friendly ClickHouse write-only message we install in UserContext.res.
// If the call did not throw, or the message is wrong, this re-throws and
// the indexer crashes the e2e test loudly.
const expectClickHouseReadOnlyError = (op: string, err: unknown) => {
  if (!(err instanceof Error)) {
    throw new Error(`Expected Error from TransferChOnly.${op}, got ${typeof err}: ${err}`);
  }
  const expected = "ClickHouse storage is currently write-only";
  if (!err.message.includes(expected)) {
    throw new Error(
      `Expected TransferChOnly.${op} error to contain "${expected}", got: ${err.message}`,
    );
  }
};

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

  // Verify the runtime blocks reads against ClickHouse-only entities with
  // a friendly message. Each call is in its own try/catch so a regression
  // surfaces against the offending operation, not as a single shared throw.
  try {
    await context.TransferChOnly.get(id);
    throw new Error("Expected context.TransferChOnly.get to throw");
  } catch (err) {
    expectClickHouseReadOnlyError("get", err);
  }

  try {
    await context.TransferChOnly.getWhere({ from: { _eq: event.params.from } });
    throw new Error("Expected context.TransferChOnly.getWhere to throw");
  } catch (err) {
    expectClickHouseReadOnlyError("getWhere", err);
  }

  // Mirror override: only ClickHouse receives this row.
  context.TransferChOnly.set({
    id,
    from: event.params.from,
    value: event.params.value,
  });
});
