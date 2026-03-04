#!/usr/bin/env node

import { fileURLToPath } from "node:url";
import { dirname } from "node:path";
import { run } from "envio/core.js";

// Tell the Rust CLI where the envio npm package lives.
// When running via napi, current_exe() returns the Node.js binary,
// so the Rust code needs this env var to locate package.json.
const coreUrl = import.meta.resolve("envio/core.js");
process.env.ENVIO_PKG_DIR = dirname(fileURLToPath(coreUrl));

run(process.argv.slice(2));
