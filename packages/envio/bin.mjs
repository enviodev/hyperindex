#!/usr/bin/env node
import { run } from "./src/Bin.res.mjs";
await run(process.argv.slice(2));
