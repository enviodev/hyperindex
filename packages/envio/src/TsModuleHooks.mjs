import module from "node:module";
import { readFileSync, statSync } from "node:fs";
import { fileURLToPath, pathToFileURL } from "node:url";
import { dirname, join, parse as parsePath } from "node:path";

const TS_EXTENSION = /\.([cm]?)tsx?$/;
const JS_EXTENSION = /\.([cm]?)jsx?$/;
const TS_EXTENSIONS = [".ts", ".tsx", ".mts", ".cts"];
const RELATIVE_SPECIFIER = /^\.{1,2}\//;

const isFile = (path) => {
  try {
    return statSync(path).isFile();
  } catch {
    return false;
  }
};

// The project tsconfig sets `moduleResolution: "bundler"`, so handlers may
// import a sibling without an extension, or spell a `.ts` sibling `.js`.
// Node's resolver does neither.
const tsCandidates = (path) => {
  if (JS_EXTENSION.test(path)) {
    return [path.replace(JS_EXTENSION, ".$1ts"), path.replace(JS_EXTENSION, ".$1tsx")];
  }
  return [
    ...TS_EXTENSIONS.map((extension) => path + extension),
    ...TS_EXTENSIONS.map((extension) => join(path, `index${extension}`)),
  ];
};

const packageType = (path) => {
  const { root } = parsePath(path);
  let directory = dirname(path);
  while (true) {
    const manifest = join(directory, "package.json");
    if (isFile(manifest)) {
      try {
        return JSON.parse(readFileSync(manifest, "utf8")).type === "module" ? "module" : "commonjs";
      } catch {
        return "commonjs";
      }
    }
    if (directory === root) return "commonjs";
    directory = dirname(directory);
  }
};

const inlineSourceMap = (map) =>
  `\n//# sourceMappingURL=data:application/json;base64,${Buffer.from(map).toString("base64")}`;

export const register = (transformTs) => {
  if (typeof module.registerHooks !== "function") {
    throw new Error(
      `Loading TypeScript handlers needs Node.js >=22.15.0 for module.registerHooks, but this process is ${process.version}.`
    );
  }

  module.registerHooks({
    resolve(specifier, context, nextResolve) {
      try {
        return nextResolve(specifier, context);
      } catch (error) {
        if (!RELATIVE_SPECIFIER.test(specifier) || context.parentURL === undefined) {
          throw error;
        }
        const candidate = tsCandidates(fileURLToPath(new URL(specifier, context.parentURL))).find(
          isFile
        );
        if (candidate === undefined) {
          throw error;
        }
        return { url: pathToFileURL(candidate).href, shortCircuit: true };
      }
    },

    load(url, context, nextLoad) {
      if (!url.startsWith("file:")) {
        return nextLoad(url, context);
      }
      const path = fileURLToPath(url);
      const extension = TS_EXTENSION.exec(path);
      if (extension === null) {
        return nextLoad(url, context);
      }

      const { code, map } = transformTs(path, readFileSync(path, "utf8"));
      return {
        format:
          extension[1] === "m" ? "module" : extension[1] === "c" ? "commonjs" : packageType(path),
        source: map ? code + inlineSourceMap(map) : code,
        shortCircuit: true,
      };
    },
  });
};
