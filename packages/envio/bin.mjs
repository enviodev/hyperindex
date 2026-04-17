#!/usr/bin/env node

// Thin CLI entry point. Loads the NAPI addon and runs the CLI in-process.

import { runCli } from "./src/Core.res.mjs";

try {
  const code = await runCli(process.argv.slice(2));
  process.exit(code);
} catch (e) {
  console.error(e.message || e);
  process.exit(1);
}
