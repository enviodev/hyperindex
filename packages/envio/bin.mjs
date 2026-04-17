#!/usr/bin/env node

// CLI entry point. Runs the CLI in-process via NAPI.
// runCli returns a JSON array of commands for JS to execute sequentially.
// This avoids NAPI async limitations — Rust queues commands, JS executes them.

import { runCli } from "./src/Core.res.mjs";

async function handleCommand(command, data) {
  switch (command) {
    case "migration-up": {
      const m = await import("envio/src/Migrations.res.mjs");
      const code = await m.runUpMigrations(false, data.reset);
      if (code !== 0) throw new Error(`Migration failed with code ${code}`);
      break;
    }
    case "migration-down": {
      const m = await import("envio/src/Migrations.res.mjs");
      const code = await m.runDownMigrations(false);
      if (code !== 0) throw new Error(`Migration failed with code ${code}`);
      break;
    }
    case "start-indexer": {
      // Clear prom-client registry — metrics were registered during
      // migrations (same process), and the indexer re-registers them.
      const promClient = await import("prom-client");
      promClient.register.clear();

      if (data.cwd) process.chdir(data.cwd);
      if (data.env) {
        for (const [k, v] of Object.entries(data.env)) {
          process.env[k] = v;
        }
      }
      // Start the indexer. Main.start() sets up event loop tasks and
      // returns immediately — the indexer runs via async dispatches.
      // When all chains finish, GlobalState calls process.exit(0).
      await import(data.indexPath);
      // Keep the process alive — the indexer terminates via process.exit().
      await new Promise(() => {});
    }
    default:
      throw new Error(`Unknown command: ${command}`);
  }
}

try {
  const commandsJson = await runCli(process.argv.slice(2));
  const commands = JSON.parse(commandsJson);
  for (const [command, data] of commands) {
    await handleCommand(command, data);
  }
} catch (e) {
  if (e.message === "__exit_0__") process.exit(0);
  console.error(e.message || e);
  process.exit(1);
}
