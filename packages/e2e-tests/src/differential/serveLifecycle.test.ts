import { expect, it } from "vitest";
import { phaseConfigs } from "./corpus.js";
import { servePort } from "./env.js";
import { spawnServe, waitForServeExit } from "./serveProcess.js";

it.runIf(process.platform !== "win32")(
  "returns control after Ctrl-C during PostgreSQL startup retry",
  async () => {
    const starting = spawnServe(phaseConfigs.default, servePort + 1, {
      ENVIO_PG_PORT: "1",
      ENVIO_SERVE_STARTUP_RETRY_BUDGET_MS: "60000",
    });
    try {
      // Local workspace runs compile the native addon before startup; CI
      // uses a packaged addon. Wait for the actual retry log so SIGINT is
      // guaranteed to exercise startup rather than the build wrapper.
      const retryDeadline = Date.now() + 60_000;
      while (
        !starting.logs.join("").includes("Retrying in") &&
        Date.now() < retryDeadline
      ) {
        await new Promise((resolve) => setTimeout(resolve, 50));
      }
      expect(starting.logs.join("")).toContain("Retrying in");
      expect(starting.child.kill("SIGINT")).toBe(true);
      await expect(waitForServeExit(starting, 5_000)).resolves.toEqual({
        code: 0,
        signal: null,
      });
    } finally {
      if (starting.child.exitCode === null) starting.child.kill("SIGKILL");
    }
  },
  75_000
);
