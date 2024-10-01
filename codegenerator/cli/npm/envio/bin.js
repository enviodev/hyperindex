#!/usr/bin/env node
//@ts-check
"use strict";

const { spawnSync } = require("child_process");

/**
 * Returns the executable path for envio located inside node_modules
 * The naming convention is envio-${os}-${arch}
 * If the platform is `win32` or `cygwin`, executable will include a `.exe` extension
 * @see https://nodejs.org/api/os.html#osarch
 * @see https://nodejs.org/api/os.html#osplatform
 * @example "x/xx/node_modules/envio-darwin-arm64"
 */
function getExePath() {
  const arch = process.arch;
  /**
   * @type string
   */
  let os = process.platform;
  let extension = "";
  if (["win32", "cygwin"].includes(process.platform)) {
    os = "windows";
    extension = ".exe";
  }

  try {
    // Since the bin will be located inside `node_modules`, we can simply call require.resolve
    return require.resolve(`envio-${os}-${arch}/bin/envio${extension}`);
  } catch (e) {
    throw new Error(
      `Couldn't find envio binary inside node_modules for ${os}-${arch}`
    );
  }
}

/**
 * Runs `envio` with args using nodejs spawn
 */
function runEnvio() {
  const args = process.argv.slice(2);
  const processResult = spawnSync(getExePath(), args, { stdio: "inherit" });
  process.exit(processResult.status ?? 0);
}

runEnvio();
