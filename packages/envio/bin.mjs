#!/usr/bin/env node
import { unsupportedNodeMessage } from "./src/NodeVersion.mjs";

// Checked before the rest loads, which an older Node may not even parse.
const unsupported = unsupportedNodeMessage();
if (unsupported !== undefined) {
  console.error(unsupported);
  process.exit(1);
}

const { run } = await import("./src/Bin.res.mjs");
await run(process.argv.slice(2));
