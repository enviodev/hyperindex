import { spawnSync } from "child_process";
import path from "path";
import { fileURLToPath } from "url";

// Run database migrations once before any test files execute. The
// previous setup ran them in beforeAll/afterAll for every test file
// which, when going through a subprocess, exceeded the per-hook timeout
// in CI.
const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const SCENARIO_ROOT = path.resolve(__dirname, "..");
const ENVIO_BIN = path.join(SCENARIO_ROOT, "node_modules/.bin/envio");

export default function setup() {
  console.log(`[global-setup] Running envio db-migrate setup from ${SCENARIO_ROOT}`);
  const result = spawnSync(ENVIO_BIN, ["local", "db-migrate", "setup"], {
    stdio: "inherit",
    cwd: SCENARIO_ROOT,
  });

  if (result.error) {
    throw result.error;
  }

  if (result.status !== 0) {
    const reason = result.signal
      ? `signal ${result.signal}`
      : `code ${result.status}`;
    throw new Error(`db-migrate setup exited with ${reason}`);
  }
  console.log(`[global-setup] db-migrate setup completed successfully`);
}
