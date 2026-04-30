#!/usr/bin/env node
import { createRequire } from "node:module";
import { spawn } from "node:child_process";
import { dirname, join } from "node:path";

const require = createRequire(import.meta.url);

let envioBin;
try {
  envioBin = join(dirname(require.resolve("envio/package.json")), "bin.mjs");
} catch (err) {
  console.error(
    "create-envio could not locate the `envio` package. " +
      "This usually means the install was interrupted; rerun `npm init envio`."
  );
  process.exit(1);
}

const child = spawn(
  process.execPath,
  [envioBin, "init", ...process.argv.slice(2)],
  { stdio: "inherit" }
);

child.on("error", (err) => {
  console.error(`Failed to launch envio init: ${err.message}`);
  process.exit(1);
});

child.on("exit", (code, signal) => {
  if (signal) {
    process.kill(process.pid, signal);
  } else {
    process.exit(code ?? 0);
  }
});
