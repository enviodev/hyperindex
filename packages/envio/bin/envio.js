#!/usr/bin/env node

import { dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { run } from "../core.js";

// Tell the Rust CLI where the envio npm package lives.
// When running via napi, current_exe() returns the Node.js binary,
// so the Rust code needs this env var to locate package.json.
const __dirname = import.meta.dirname ?? dirname(fileURLToPath(import.meta.url));
process.env.ENVIO_PKG_DIR = dirname(__dirname);

run(process.argv.slice(2));
