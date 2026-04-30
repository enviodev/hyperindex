import { spawnSync } from "child_process";
import path from "path";
import { describe, it, expect } from "vitest";

// Regression test for db-migrate setup/down hanging after the postgres pool's
// idle TCP sockets kept Node's event loop alive. The commands must exit
// cleanly on their own — no signal, status 0 — well within the timeout.
const ENVIO_BIN = path.resolve(
  import.meta.dirname,
  "../node_modules/envio/bin.mjs",
);
const PROJECT_ROOT = path.resolve(import.meta.dirname, "..");

const runEnvio = (args: string[]) =>
  spawnSync(process.execPath, [ENVIO_BIN, ...args], {
    cwd: PROJECT_ROOT,
    encoding: "utf-8",
    timeout: 15_000,
    env: {
      ...process.env,
      ENVIO_PG_PORT: "5433",
      // Hasura isn't reachable in the test environment; without this, retries
      // dominate runtime and obscure whether the process actually exited.
      ENVIO_HASURA: "false",
    },
  });

describe("envio local db-migrate", () => {
  it("setup exits cleanly without hanging", () => {
    const result = runEnvio(["local", "db-migrate", "setup"]);
    expect({ status: result.status, signal: result.signal }).toEqual({
      status: 0,
      signal: null,
    });
  });

  it("down exits cleanly without hanging", () => {
    const result = runEnvio(["local", "db-migrate", "down"]);
    expect({ status: result.status, signal: result.signal }).toEqual({
      status: 0,
      signal: null,
    });
  });
});
