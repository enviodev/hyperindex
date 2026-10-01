import { indexer } from "envio";
// No extension: `moduleResolution: "bundler"` allows it, Node's resolver does not.
import { contractName } from "./names";
// `.js` spelling of a `.ts` sibling.
import { eventName } from "./events.js";

// Not erasable syntax, so Node's built-in type stripping rejects this module.
enum Direction {
  In = "in",
  Out = "out",
}

indexer.onEvent({ contract: contractName, event: eventName }, async ({ event, context }) => {
  context.Transfer.set({
    id: `${event.chainId}_${event.block.number}_${event.logIndex}`,
    direction: Direction.In,
  });
});
