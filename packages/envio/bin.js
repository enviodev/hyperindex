#!/usr/bin/env node
//@ts-check

import { spawnSync } from "child_process";
import { createRequire } from "module";

const require = createRequire(import.meta.url);

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
   * @type {string}
   */
  let os = process.platform;
  let extension = "";
  if (["win32", "cygwin"].includes(process.platform)) {
    os = "windows";
    extension = ".exe";
  }

  const pkg = `envio-${os}-${arch}`;
  try {
    // Since the bin will be located inside `node_modules`, we can simply call require.resolve
    return require.resolve(`${pkg}/bin/envio${extension}`);
  } catch (e) {
    throw new Error(
      `Couldn't find envio binary package "${pkg}" inside node_modules.\n` +
        `If you're using pnpm, yarn, or npm with --omit=optional, ensure optional ` +
        `dependencies are installed:\n` +
        `  npm install envio-${os}-${arch}\n`
    );
  }
}

/**
 * Runs `envio` with args using nodejs spawn
 */
function runEnvio() {
  const args = process.argv.slice(2);
  const exePath = getExePath();

  const processResult = spawnSync(exePath, args, { stdio: "inherit" });

  if (processResult.error) {
    console.error(`Failed to run envio binary at ${exePath}: ${processResult.error.message}`);
    process.exit(1);
  }
  process.exit(processResult.status ?? 1);
}

runEnvio();
