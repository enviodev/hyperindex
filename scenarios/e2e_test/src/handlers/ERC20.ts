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

const idsOf = (transfers: { id: string }[]) =>
  transfers
    .map((transfer) => transfer.id)
    .sort()
    .join(",");

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

  // TransferPgOnly and TransferChOnly are written alike, each to the one store
  // its @storage names, so whichever store answers, a read has to find the
  // same transfers in both — and nothing yet under this event's own id.
  const [pgExisting, chExisting, pgSent, chSent] = await Promise.all([
    context.TransferPgOnly.get(id),
    context.TransferChOnly.get(id),
    context.TransferPgOnly.getWhere({ from: { _eq: event.params.from } }),
    context.TransferChOnly.getWhere({ from: { _eq: event.params.from } }),
  ]);
  if (pgExisting !== undefined || chExisting !== undefined) {
    throw new Error(`A transfer under ${id} exists before the event that sets it`);
  }
  if (idsOf(pgSent) !== idsOf(chSent)) {
    throw new Error(
      `The stores disagree on ${event.params.from}'s transfers:\n  Postgres: ${idsOf(pgSent)}\n  ClickHouse: ${idsOf(chSent)}`,
    );
  }

  // Per-entity storage override: only Postgres receives this row (declared in
  // schema.graphql via @storage(postgres: true)).
  context.TransferPgOnly.set({
    id,
    from: event.params.from,
    value: event.params.value,
  });

  // @internal entity: written like any other, but invisible to Hasura.
  context.TransferInternal.set({
    id,
    from: event.params.from,
    value: event.params.value,
  });

  // Per-entity storage override: only ClickHouse receives this row.
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
