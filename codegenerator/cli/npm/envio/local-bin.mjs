#!/usr/bin/env node

import { spawnSync } from "child_process";
import path from "path";
import { fileURLToPath } from "url";

/**
 * Runs `envio` with args using nodejs spawn
 */
function runLocalEnvio() {
  const args = process.argv.slice(2);
  const __filename = fileURLToPath(import.meta.url); // get the resolved path to the file
  const __dirname = path.dirname(__filename); // get the name of the directory
  const processResult = spawnSync(
    "cargo",
    [
      "run",
      "--manifest-path",
      path.join(__dirname, "../../Cargo.toml"),
      ...args,
    ],
    { stdio: "inherit" }
  );
  process.exit(processResult.status ?? 0);
}

runLocalEnvio();
