import { indexer } from "envio";

indexer.onEvent({ contract: "Token", event: "Transfer" }, async ({ event, context }) => {
  context.Transfer.set({ id: `${event.chainId}_${event.block.number}_${event.logIndex}` });
});
