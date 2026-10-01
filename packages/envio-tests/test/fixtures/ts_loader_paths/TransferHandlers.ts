import { indexer } from "envio";
// Mapped by tsconfig `paths`.
import { contractName } from "@lib/names";
// Resolved against tsconfig `baseUrl`.
import { eventName } from "lib/events";

indexer.onEvent({ contract: contractName, event: eventName }, async ({ event, context }) => {
  context.Transfer.set({ id: `${event.chainId}_${event.block.number}_${event.logIndex}` });
});
