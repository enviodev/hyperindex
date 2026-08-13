import { indexer } from "envio";
// No extension: `moduleResolution: "bundler"` allows it, Node's resolver does not.
import { isWildcard } from "./flags";
// `.js` spelling of a `.ts` sibling.
import { transferEvent } from "./names.js";

// Not erasable syntax: loading this module at all proves the handler transform
// lowers enums rather than only stripping types.
enum Sentinel {
  Unset,
  Set,
}

let sentinel = Sentinel.Unset;

indexer.onEvent(
  { contract: "EventFiltersTest", event: transferEvent, wildcard: isWildcard },
  async () => {
    sentinel = Sentinel.Set;
    if (sentinel !== Sentinel.Set) {
      throw new Error("unreachable");
    }
  }
);
