/**
 * `envio dev` starts the project's sidecar next to the indexer, with the
 * loopback URLs Envio Cloud gives the sidecar container, and stops it again.
 */

import { describe, it, expect } from "vitest";
import { execFile } from "child_process";
import { promisify } from "util";
import fs from "fs";
import { createRequire } from "module";
import os from "os";
import path from "path";
import { config } from "../config.js";
import { startBackground, waitForOutput } from "../utils/process.js";

// Same rule as e2e.test.ts: `envio dev` needs Docker for Postgres and Hasura.
const dockerAvailable = await (async () => {
  try {
    await promisify(execFile)("docker", ["info"], { timeout: 15_000 });
    return true;
  } catch {
    return false;
  }
})();

if (!dockerAvailable && process.env.CI) {
  throw new Error("Docker is unavailable, so the e2e suite cannot run. Refusing to skip it in CI.");
}

const isRunning = (pid: number) => {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
};

describe.skipIf(!dockerAvailable)("envio dev with a sidecar", () => {
  it("starts the sidecar with the loopback URLs and stops it with the indexer", async () => {
    // A copy, so codegen output never lands in the fixture.
    const projectDir = fs.mkdtempSync(path.join(os.tmpdir(), "envio-sidecar-dev-"));
    fs.cpSync(path.join(config.rootDir, "packages/e2e-tests/fixtures/sidecar-project"), projectDir, {
      recursive: true,
    });
    // The installed envio, like config.envioCommand: in CI the source
    // checkout has no compiled `.res.mjs`, only the installed artifact does.
    fs.mkdirSync(path.join(projectDir, "node_modules"));
    fs.symlinkSync(
      path.dirname(createRequire(import.meta.url).resolve("envio/package.json")),
      path.join(projectDir, "node_modules/envio")
    );

    const dev = startBackground(
      config.envioCommand,
      [...config.envioArgs, "dev", "--config", "sidecar.config.yaml"],
      {
        cwd: projectDir,
        env: {
          ENVIO_TUI: "false",
          ENVIO_API_TOKEN: process.env.ENVIO_API_TOKEN ?? "",
          ENVIO_PG_SCHEMA: `envio_test_${Date.now()}_${process.pid}_sidecardev`,
          // Off the default 9898, which e2e.test.ts's indexer may hold.
          ENVIO_INDEXER_PORT: "9897",
        },
      }
    );
    const output: string[] = [];
    dev.stdout?.on("data", (data) => output.push(data.toString()));
    dev.stderr?.on("data", (data) => output.push(data.toString()));
    const exited = new Promise<number | null>((resolve) => dev.on("close", resolve));

    try {
      await waitForOutput(dev, "fake sidecar started", 60_000);
    } finally {
      dev.kill("SIGTERM");
      await exited;
    }
    const started = output.join("").match(/fake sidecar started .* pid=(\d+) env=(.*)/);
    // The child logs its close a moment after the parent is gone.
    await new Promise((resolve) => setTimeout(resolve, 1_000));
    const sidecarPid = Number(started?.[1]);

    expect({
      env: started?.[2]?.trim(),
      closed: output.join("").includes("fake sidecar closed"),
      sidecarStillRunning: isRunning(sidecarPid),
    }).toEqual({
      env: "http://127.0.0.1:9901 http://127.0.0.1:9899 9900 http://localhost:8080/v1/graphql",
      closed: true,
      sidecarStillRunning: false,
    });
    fs.rmSync(projectDir, { recursive: true, force: true });
  }, 180_000);
});
