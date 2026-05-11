import { spawnSync } from "child_process";
import path from "path";
import { describe, it, expect } from "vitest";

const ENVIO_BIN = path.resolve(
  import.meta.dirname,
  "../node_modules/envio/bin.mjs",
);
const PROJECT_ROOT = path.resolve(import.meta.dirname, "..");

describe("envio config view", () => {
  it("prints the config as JSON", () => {
    const result = spawnSync(
      process.execPath,
      [ENVIO_BIN, "config", "view"],
      {
        cwd: PROJECT_ROOT,
        encoding: "utf-8",
        timeout: 15_000,
      },
    );

    expect({
      status: result.status,
      signal: result.signal,
      parsed: JSON.parse(result.stdout),
    }).toMatchInlineSnapshot(`
      {
        "parsed": {
          "version": "0.0.1-dev",
        },
        "signal": null,
        "status": 0,
      }
    `);
  });
});
