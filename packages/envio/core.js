/* eslint-disable */

/**
 * Loads the platform-specific native module (envio.node).
 *
 * Resolution order:
 *   1. Platform package installed as optional dependency (envio-{os}-{arch})
 *   2. Local envio.node next to this file (CI artifacts or local dev build)
 */

import { createRequire } from "node:module";
import { platform, arch } from "node:process";

const require = createRequire(import.meta.url);

const PLATFORM_MAP = {
  darwin: "darwin",
  linux: "linux",
};

const ARCH_MAP = {
  x64: "x64",
  arm64: "arm64",
};

function loadNativeModule() {
  const os = PLATFORM_MAP[platform];
  const cpu = ARCH_MAP[arch];

  if (!os || !cpu) {
    throw new Error(
      `Unsupported platform: ${platform}-${arch}. ` +
        `Supported: darwin-x64, darwin-arm64, linux-x64, linux-arm64`
    );
  }

  const pkgName = `envio-${os}-${cpu}`;

  // Try platform package first (installed via optionalDependencies)
  try {
    return require(`${pkgName}/envio.node`);
  } catch (_) {}

  // Fallback: local .node file (CI artifacts or local dev build)
  try {
    return require("./envio.node");
  } catch (_) {}

  throw new Error(
    `Failed to load native module for ${platform}-${arch}. ` +
      `Ensure the platform package '${pkgName}' is installed, ` +
      `or build locally with 'cargo build --lib --features napi'.`
  );
}

const native = loadNativeModule();

export const run = native.run;
