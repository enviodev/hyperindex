#!/usr/bin/env node
/**
 * Generates a publish-ready package.json for a platform-specific binary package.
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
    // Optional libc flavor for linux ("glibc" | "musl"). Appends "-musl" to
    // the package name when "musl" and sets npm's `libc` field so npm/pnpm
    // picks the right optional dependency on the install host.
    libc: { type: "string" as const },
    out: { type: "string" as const },
  },
  strict: true,
});

if (!values.version || !values.platform || !values.arch || !values.out) {
  console.error(
    "Usage: node build-platform-package.ts --version <v> --platform <os> --arch <arch> [--libc <glibc|musl>] --out <dir>"
  );
  process.exit(1);
}

const { version, platform, arch, libc, out } = values;
const name =
  libc === "musl" ? `envio-${platform}-${arch}-musl` : `envio-${platform}-${arch}`;

const pkg: Record<string, unknown> = {
  name,
  version,
  main: "./envio.node",
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
  os: [platform],
  cpu: [arch],
};

if (platform === "linux" && libc) {
  pkg.libc = [libc];
}

mkdirSync(out, { recursive: true });
writeFileSync(join(out, "package.json"), JSON.stringify(pkg, null, 2) + "\n");
console.log(`Wrote ${join(out, "package.json")} for ${name}@${version}`);

// Copy README from packages/cli/README.md
const repoRoot = resolve(dirname(new URL(import.meta.url).pathname), "../../");
const readmeSrc = join(repoRoot, "packages/cli/README.md");
copyFileSync(readmeSrc, join(out, "README.md"));
console.log(`Copied README to ${join(out, "README.md")}`);
