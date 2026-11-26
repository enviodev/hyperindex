import { mergeConfig } from "vitest/config";
import base from "./vitest.config.ts";

// Benchmarks are tests that print a measurement instead of asserting one, kept
// out of `pnpm test` so CI time doesn't depend on them.
const config = mergeConfig(base, { test: { fileParallelism: false } });
// Set after merging: mergeConfig appends arrays, which would keep every test.
config.test.include = ["test/bench/**/*_bench.res.mjs"];
export default config;
