import { createRequire } from "node:module";

// `Core.loadAddon` tries the platform package before `ENVIO_DEV_ADDON`, so an
// addon staged into node_modules silently shadows the one being measured — and
// a debug build there against a release build elsewhere reads as a regression
// in the code rather than in the build. Refuse to guess which one ran.
const platformPackage = `envio-${process.platform}-${process.arch}`;
try {
  const shadowing = createRequire(import.meta.url).resolve(platformPackage);
  throw new Error(
    `${platformPackage} is installed at ${shadowing} and takes precedence over ` +
      `ENVIO_DEV_ADDON, so the bench would not measure the addon you point it at. ` +
      `Remove it for the run.`,
  );
} catch (error) {
  if (error.code !== "MODULE_NOT_FOUND") throw error;
}

if (!process.env.ENVIO_DEV_ADDON) {
  throw new Error("Set ENVIO_DEV_ADDON to the addon to measure.");
}

const { run } = await import("../test/helpers/StagingBench.res.mjs");
await run();
