import { spawnSync } from "node:child_process";
import { createRequire } from "node:module";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";

const here = path.dirname(fileURLToPath(import.meta.url));
const tsc = createRequire(import.meta.url).resolve("typescript/bin/tsc");

// A user-shaped sidecar project compiled with the template tsconfig: what a
// customer's editor and `tsc` would say about `envio/sidecar`.
describe("sidecar types", () => {
  it("type checks a user-shaped sidecar project, including the mistakes it must catch", () => {
    const result = spawnSync(process.execPath, [tsc, "-p", path.join(here, "fixtures", "user", "tsconfig.json"), "--pretty", "false"], {
      encoding: "utf8",
    });
    expect({ status: result.status, output: result.stdout + result.stderr }).toEqual({ status: 0, output: "" });
  });
});
