#!/usr/bin/env node
//@ts-check
"use strict";

import { spawnSync } from "child_process";
import { existsSync } from "fs";
import path from "path";

/**
 * Runs `envio` with args using nodejs spawn
 */
function runLocalEnvio() {
  const args = process.argv.slice(2);

  const caller = process.argv[1];
  if (!caller.endsWith("/node_modules/envio/local-bin.mjs")) {
    throw new Error(
      `Unexpected call to local envio package. Either use cargo or use the local package via npm scripts. Caller: ${caller}`
    );
  }

  let root = path.join(caller, "../../..");

  const pnpmListResult = spawnSync("pnpm", ["list", "envio", "--json"], {
    cwd: root,
  });
  if (pnpmListResult.status !== 0) {
    throw new Error(
      `Failed to run pnpm list envio --json. Error: ${pnpmListResult.stderr}`
    );
  }
  let pnpmList;
  try {
    const outputString = pnpmListResult.output.toString();
    // It starts and ends with , so we need to remove it before parsing
    const jsonString = outputString.slice(1, -1);
    pnpmList = JSON.parse(jsonString);
  } catch (e) {
    throw new Error(
      `Invalid pnpm list envio --json output. Error: ${e.message}`
    );
  }

  let envioVersion;
  try {
    envioVersion = pnpmList[0].dependencies["envio"].version;
  } catch (e) {
    throw new Error(
      `Failed to get envio version from pnpm list envio --json output. Error: ${e.message}`
    );
  }

  if (!envioVersion.startsWith("file:")) {
    throw new Error(
      `Unexpected envio version. It should have the file: protocol. Actual: ${envioVersion}`
    );
  }

  // It should be correctly set by lenvio init command,
  // so we can rely on it to find a path to the local repository.
  // We can't use the actual path from the node_modules folder,
  // because it's stored in the global .pnpm and we can't get a path to binary using it.
  const relativeLocalEnvioPath = envioVersion.replace("file:", "");

  // Validate the path doesn't contain traversal sequences before using it
  const manifestPath = path.resolve(
    root,
    relativeLocalEnvioPath,
    "../../Cargo.toml"
  );
  if (!existsSync(manifestPath)) {
    throw new Error(
      `Cargo.toml not found at resolved path. Ensure the envio file: dependency in package.json points to a valid local checkout.`
    );
  }

  const processResult = spawnSync(
    "cargo",
    ["run", "--manifest-path", manifestPath, ...args],
    { stdio: "inherit" }
  );
  process.exit(processResult.status ?? 0);
}

runLocalEnvio();
