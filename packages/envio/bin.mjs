#!/usr/bin/env node

// CLI entry point. Loads the NAPI addon and runs the CLI in-process.
// The callback executes JS scripts (migrations, indexer) in-process
// and signals completion back to Rust via signalComplete/signalError.

import { runCli, signalComplete, signalError } from "./src/Core.res.mjs";

try {
  const code = await runCli(
    process.argv.slice(2),
    // Rust sends "id|script". We eval the script async, then signal
    // completion back to Rust via sync NAPI calls.
    (_err, payload) => {
      const sep = payload.indexOf("|");
      const id = Number(payload.substring(0, sep));
      const script = payload.substring(sep + 1);
      (async () => {
        try {
          const result = await (0, eval)(script);
          // Migrations return an exit code (0=success, 1=failure)
          if (typeof result === "number" && result !== 0) {
            signalError(id, `Script returned non-zero exit code: ${result}`);
          } else {
            signalComplete(id);
          }
        } catch (e) {
          signalError(id, e?.message ?? String(e));
        }
      })();
    }
  );
  process.exit(code);
} catch (e) {
  console.error(e.message || e);
  process.exit(1);
}
