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
        // Index.res exports `promise` — the async main() that runs the
        // indexer. We await it so Rust knows when the indexer finishes
        // (or crashes). Without this, import() resolves immediately
        // after module load and Rust thinks the indexer is done.
        const indexModule = await import(data.indexPath);
        await indexModule.promise;
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
