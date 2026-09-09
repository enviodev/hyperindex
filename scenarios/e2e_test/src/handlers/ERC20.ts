import { indexer, BigDecimal } from "envio";

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

// Asserts that an error thrown by a context.<entity>.<op>() call matches
// the friendly ClickHouse write-only message we install in UserContext.res
// verbatim. If the call did not throw, or the message is wrong, this
// re-throws and the indexer crashes the e2e test loudly.
const expectClickHouseReadOnlyError = (op: string, err: unknown) => {
  if (!(err instanceof Error)) {
    throw new Error(`Expected Error from TransferChOnly.${op}, got ${typeof err}: ${err}`);
  }
  const expected =
    `context.TransferChOnly.${op}() is unavailable: ` +
    `ClickHouse storage is currently write-only. ` +
    `Follow Envio releases to be notified when ClickHouse supports both reads and writes from handlers.`;
  if (err.message !== expected) {
    throw new Error(
      `Expected TransferChOnly.${op} error:\n  ${expected}\nGot:\n  ${err.message}`,
    );
  }
};

// Asserted by the ClickHouse parity suite, which needs an id it knows was
// deleted rather than one that happens to be.
const HOLDER_DELETED_SENTINEL = "holder-deleted-sentinel";

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

  // @internal entity: written like any other, but invisible to Hasura.
  context.TransferInternal.set({
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

  // Per-chain entities: the same id on another chain would be a separate row,
  // and the ChainAccount -> ChainTransfer relationship must stay within a chain.
  context.ChainTransfer.set({
    id,
    from: event.params.from,
    value: event.params.value,
  });
  context.ChainAccount.set({ id: event.params.from });

  // Deleted on some events and set again on later ones, so the ClickHouse view
  // has to resolve an id whose history interleaves SET and DELETE.
  if (event.logIndex % 7 === 6) {
    context.Holder.deleteUnsafe(event.params.from);
  } else {
    context.Holder.set({
      id: event.params.from,
      lastBlock: event.block.number,
      lastValue: event.params.value,
    });
  }

  // Set and deleted within one event, so both backends are guaranteed at least
  // one id whose final state is deleted no matter what the block range holds.
  context.Holder.set({
    id: HOLDER_DELETED_SENTINEL,
    lastBlock: event.block.number,
    lastValue: event.params.value,
  });
  context.Holder.deleteUnsafe(HOLDER_DELETED_SENTINEL);

  // Values are chosen beyond float64 precision so a regression that lets
  // Hasura serve NUMERIC[] as numbers changes the digits, not just the type.
  context.NumericArrays.set({
    id: "1",
    bigInts: [9007199254740993n, 1000000000000000000000000000n],
    bigDecimals: [
      new BigDecimal("3.3"),
      new BigDecimal("123456789012345678.123456789"),
    ],
  });
});
