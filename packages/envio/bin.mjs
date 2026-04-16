#!/usr/bin/env node

// CLI entry point. Loads the NAPI addon and runs the CLI in-process.
// Passes a JS callback so Rust can execute JS code (migrations,
// indexer start) without spawning child Node processes.

import { runCli } from "./src/Core.res.mjs";

try {
  const code = await runCli(
    process.argv.slice(2),
    // JS runner callback: Rust calls this to execute scripts in-process.
    // NAPI uses error-first convention: callback(error, value).
    async (_err, script) => {
      await (0, eval)(script);
    }
  );
  process.exit(code);
} catch (e) {
  console.error(e.message || e);
  process.exit(1);
}
