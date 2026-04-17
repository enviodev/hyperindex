#!/usr/bin/env node

// CLI entry point. Runs the CLI in-process via NAPI.
// The callback handles JS-side operations (migrations, indexer start)
// that Rust delegates instead of spawning child processes.

import { runCli, signalComplete, signalError } from "./src/Core.res.mjs";

async function handleCommand(id, command, data) {
  try {
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
        // The indexer is a long-running process. Main.start() sets up
        // event loop tasks and returns immediately — the indexer runs
        // via async dispatches until all chains finish (endBlock) or
        // indefinitely (no endBlock).
        //
        // We spawn a child node process for this because:
        // 1. Main.start doesn't return a Promise that tracks completion
        // 2. The indexer needs its own clean module state (no prom-client
        //    collisions from migration imports)
        // 3. The TUI/stdin needs a clean process context
        const { spawn } = await import("node:child_process");
        const child = spawn("node", ["--no-warnings", data.indexPath], {
          cwd: data.cwd,
          env: { ...process.env, ...data.env },
          stdio: "inherit",
        });
        await new Promise((resolve, reject) => {
          child.on("close", (code) => {
            if (code === 0) resolve();
            else reject(new Error(`Indexer exited with code ${code}`));
          });
          child.on("error", reject);
        });
        break;
      }
      default:
        throw new Error(`Unknown command: ${command}`);
    }
    signalComplete(id);
  } catch (e) {
    signalError(id, e?.message ?? String(e));
  }
}

try {
  const code = await runCli(
    process.argv.slice(2),
    // Rust sends "id|command|json-data". No eval — just structured dispatch.
    (_err, payload) => {
      const firstSep = payload.indexOf("|");
      const secondSep = payload.indexOf("|", firstSep + 1);
      const id = Number(payload.substring(0, firstSep));
      const command = payload.substring(firstSep + 1, secondSep);
      const data = JSON.parse(payload.substring(secondSep + 1));
      handleCommand(id, command, data);
    }
  );
  process.exit(code);
} catch (e) {
  console.error(e.message || e);
  process.exit(1);
}
