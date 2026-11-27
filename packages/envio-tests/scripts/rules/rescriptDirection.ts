// New runtime logic goes in Rust, so the ReScript runtime should shrink over
// time. A change can still grow it for a good reason (bindings to a new Rust
// class), which is why this is a number to read and not a budget to fail on.

import type { file } from "./shared.ts";
import { isRescript, runtimeRoot } from "./shared.ts";

export type direction = { net: number; changed: { path: string; net: number }[] };

const nonBlankLinesByPath = (files: file[]) =>
  new Map(
    files
      .filter((file) => file.path.startsWith(runtimeRoot) && isRescript(file))
      .map(({ path, text }) => [path, text.split("\n").filter((line) => line.trim() !== "").length]),
  );

export const summarizeRescriptDirection = (base: file[], head: file[]): direction => {
  const before = nonBlankLinesByPath(base);
  const after = nonBlankLinesByPath(head);
  const changed = [...new Set([...before.keys(), ...after.keys()])]
    .sort()
    .map((path) => ({ path, net: (after.get(path) ?? 0) - (before.get(path) ?? 0) }))
    .filter(({ net }) => net !== 0);
  return { net: changed.reduce((sum, { net }) => sum + net, 0), changed };
};
