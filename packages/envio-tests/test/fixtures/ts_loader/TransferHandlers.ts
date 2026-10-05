import { indexer } from "envio";
// No extension: `moduleResolution: "bundler"` allows it, Node's resolver does not.
import { contractName } from "./names";
// `.js` spelling of a `.ts` sibling.
import { eventName } from "./events.js";
// `resolveJsonModule` allows this without the `type: "json"` attribute Node requires.
import labels from "./labels.json";
// Extensionless import of a plain `.js` sibling, which `allowJs` permits.
import { label } from "./format";
// Both `dup.ts` and `dup.js` exist; like tsx, the TypeScript file wins.
import { source } from "./dup.js";
// A TypeScript library whose package.json doesn't declare `"type": "module"`,
// as a workspace package often doesn't. Only handlers have to.
import { scope } from "../ts_loader_lib/index.js";

// Not erasable syntax, so Node's built-in type stripping rejects this module.
enum Direction {
  In = "in",
  Out = "out",
}

indexer.onEvent({ contract: contractName, event: eventName }, async ({ event, context }) => {
  context.Transfer.set({
    id: `${event.chainId}_${event.block.number}_${event.logIndex}`,
    direction: `${label(labels[Direction.In])}:${source}:${scope}`,
  });
});
