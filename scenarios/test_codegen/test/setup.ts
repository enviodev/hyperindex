// Importing Env triggers Logging.setLogger as a side effect,
// ensuring the logger is available for all tests.
import "envio/src/Env.res.mjs";

import { expect } from "vitest";

// Strict counterpart to the built-in `toThrowError`, which only checks that the
// thrown message *contains* the expected string. `toThrowErrorEqual` requires
// the whole message to match, so a test can pin the complete error text.
expect.extend({
  toThrowErrorEqual(received: unknown, expected: string) {
    if (typeof received !== "function") {
      return {
        pass: false,
        message: () =>
          `toThrowErrorEqual expects a function to invoke, received ${typeof received}.`,
      };
    }
    let thrown: unknown;
    let didThrow = false;
    try {
      received();
    } catch (error) {
      didThrow = true;
      thrown = error;
    }
    if (!didThrow) {
      return {
        pass: false,
        message: () => "expected the function to throw, but it did not.",
      };
    }
    const actual = thrown instanceof Error ? thrown.message : String(thrown);
    const pass = actual === expected;
    return {
      pass,
      message: () =>
        pass
          ? `expected the thrown message not to equal:\n${JSON.stringify(expected)}`
          : `expected the thrown message to equal:\n${JSON.stringify(
              expected,
            )}\nreceived:\n${JSON.stringify(actual)}`,
    };
  },
});
