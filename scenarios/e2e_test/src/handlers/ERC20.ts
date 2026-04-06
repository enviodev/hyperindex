import { indexer } from "generated";

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
