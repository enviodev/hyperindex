/**
 * Where AssemblyScript finds a library that has no JavaScript entry.
 *
 * `asc` resolves `import { decode } from "as-base64"` to the package's
 * `assembly/index.ts` (or the file its package.json names as `ascMain`), and a
 * subpath such as `as-bignum/assembly/integer/u128` to the TypeScript file of
 * that name. Node only knows `main`/`exports`, so `as-base64` — whose
 * package.json names neither — is "Cannot find package .../index.js". This is
 * the AssemblyScript half of resolution, run only after Node has failed.
 */

import { existsSync, readFileSync, statSync } from "node:fs";
import { fileURLToPath, pathToFileURL } from "node:url";
import path from "node:path";

function isFile(file: string): boolean {
  try {
    return statSync(file).isFile();
  } catch {
    return false;
  }
}

/** The package name and the path inside it: `@scope/pkg/sub/file` → [`@scope/pkg`, `sub/file`]. */
function splitSpecifier(specifier: string): [string, string] | null {
  const parts = specifier.split("/");
  const nameLength = specifier.startsWith("@") ? 2 : 1;
  if (parts.length < nameLength || parts.slice(0, nameLength).some((part) => part === "")) return null;
  return [parts.slice(0, nameLength).join("/"), parts.slice(nameLength).join("/")];
}

/** The `.ts` file AssemblyScript would load for `specifier` imported from `parentUrl`, as a URL. */
export function resolveAssemblyScriptPackage(specifier: string, parentUrl: string | undefined): string | null {
  if (!parentUrl?.startsWith("file:")) return null;
  if (specifier.startsWith(".") || specifier.startsWith("/") || specifier.startsWith("node:")) return null;
  const split = splitSpecifier(specifier);
  if (!split) return null;
  const [name, inner] = split;

  let dir = path.dirname(fileURLToPath(parentUrl));
  for (;;) {
    const packageDir = path.join(dir, "node_modules", name);
    if (existsSync(packageDir)) {
      const found = resolveInPackage(packageDir, inner);
      if (found) return pathToFileURL(found).href;
    }
    const up = path.dirname(dir);
    if (up === dir) return null;
    dir = up;
  }
}

function resolveInPackage(packageDir: string, inner: string): string | null {
  const candidates: string[] = [];
  if (inner === "") {
    let manifest: { ascMain?: unknown; types?: unknown } = {};
    try {
      manifest = JSON.parse(readFileSync(path.join(packageDir, "package.json"), "utf8"));
    } catch {
      // A package without a readable manifest still has its assembly/ directory.
    }
    if (typeof manifest.ascMain === "string") candidates.push(manifest.ascMain);
    candidates.push("assembly/index.ts");
    if (typeof manifest.types === "string" && manifest.types.endsWith(".ts") && !manifest.types.endsWith(".d.ts")) {
      candidates.push(manifest.types);
    }
    candidates.push("index.ts");
  } else {
    candidates.push(inner, `${inner}.ts`, path.join(inner, "index.ts"), path.join("assembly", inner, "index.ts"));
  }
  for (const candidate of candidates) {
    const file = path.join(packageDir, candidate);
    if (candidate.endsWith(".ts") && !candidate.endsWith(".d.ts") && isFile(file)) return file;
  }
  return null;
}
