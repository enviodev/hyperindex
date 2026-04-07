import { spawnSync } from "child_process";

// Run database migrations once before any test files execute. The
// previous setup ran them in beforeAll/afterAll for every test file
// which, when going through a subprocess, exceeded the per-hook timeout
// in CI.
export default function setup() {
  const result = spawnSync(
    "./node_modules/.bin/envio",
    ["local", "db-migrate", "setup"],
    {
      stdio: "inherit",
      cwd: process.cwd(),
    }
  );

  if (result.error) {
    throw result.error;
  }

  if (result.status !== 0) {
    const reason = result.signal
      ? `signal ${result.signal}`
      : `code ${result.status}`;
    throw new Error(`db-migrate setup exited with ${reason}`);
  }
}
