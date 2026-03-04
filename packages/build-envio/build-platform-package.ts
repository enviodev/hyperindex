#!/usr/bin/env node
/**
 * Generates a publish-ready package.json for a platform-specific native module package.
 *
 * Usage:
 *   node build-platform-package.ts --version <version> --platform <os> --arch <arch> --out <dir>
 */

import { writeFileSync, copyFileSync, mkdirSync } from "node:fs";
import { join, resolve, dirname } from "node:path";
import { parseArgs } from "node:util";

const { values } = parseArgs({
  options: {
    version: { type: "string" as const },
    platform: { type: "string" as const },
    arch: { type: "string" as const },
    out: { type: "string" as const },
  },
  strict: true,
});

if (!values.version || !values.platform || !values.arch || !values.out) {
  console.error(
    "Usage: node build-platform-package.ts --version <v> --platform <os> --arch <arch> --out <dir>"
  );
  process.exit(1);
}

const { version, platform, arch, out } = values;
const name = `envio-${platform}-${arch}`;

const pkg = {
  name,
  version,
  description:
    "A latency and sync speed optimized, developer friendly blockchain data indexer.",
  repository: {
    type: "git",
    url: "git+https://github.com/enviodev/hyperindex.git",
  },
  keywords: ["blockchain", "indexer", "ethereum", "data", "dapp"],
  author: "envio contributors <about@envio.dev>",
  license: "GPL-3.0",
  bugs: { url: "https://github.com/enviodev/hyperindex/issues" },
  homepage: "https://envio.dev",
  files: ["envio.node"],
  os: [platform],
  cpu: [arch],
};

mkdirSync(out, { recursive: true });
writeFileSync(join(out, "package.json"), JSON.stringify(pkg, null, 2) + "\n");
console.log(`Wrote ${join(out, "package.json")} for ${name}@${version}`);

// Copy README from packages/cli/README.md
const repoRoot = resolve(dirname(new URL(import.meta.url).pathname), "../../");
const readmeSrc = join(repoRoot, "packages/cli/README.md");
copyFileSync(readmeSrc, join(out, "README.md"));
console.log(`Copied README to ${join(out, "README.md")}`);
