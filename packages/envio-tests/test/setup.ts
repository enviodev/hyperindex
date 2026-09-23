// Importing Env triggers Logging.setLogger as a side effect,
// ensuring the logger is available for all tests.
import "envio/src/Env.res.mjs";
import * as ItemBuffer from "envio/src/ItemBuffer.res.mjs";
import { expect } from "vitest";

// A buffer keeps its items at whatever slots Rust handed out, so two buffers
// holding the same items in the same order can lay them out differently.
// Compare what they hold instead, so a fetch state compared whole still checks
// its buffer.
const isItemBuffer = (value: unknown): value is ItemBuffer.t =>
  typeof value === "object" &&
  value !== null &&
  "native" in value &&
  "slots" in value &&
  (value as { native: object }).native?.constructor?.name === "ItemBuffer";

expect.addEqualityTesters([
  function (a, b) {
    if (isItemBuffer(a) && isItemBuffer(b)) {
      return this.equals(ItemBuffer.toArray(a), ItemBuffer.toArray(b));
    }
    return undefined;
  },
]);
