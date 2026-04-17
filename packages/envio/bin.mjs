#!/usr/bin/env node
import { run } from "./src/Bin.res.mjs";
try {
  await run(process.argv.slice(2));
} catch (e) {
  if (e.message === "__exit_0__") process.exit(0);
  console.error(e.message || e);
  process.exit(1);
}
