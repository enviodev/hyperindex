import module from "node:module";
import { readFileSync, statSync } from "node:fs";
import { fileURLToPath, pathToFileURL } from "node:url";
import { dirname, join, parse as parsePath } from "node:path";

const TS_EXTENSION = /\.([cm]?)tsx?$/;

const isFile = (path) => {
  try {
    return statSync(path).isFile();
  } catch {
    return false;
  }
};

// Only decides the format of a file without `import`/`export`, which is a
// script in either format. Like Node's own detection, it is CommonJS unless the
// package says `module`.
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

export const register = (transformTs, resolveTs) => {
  if (typeof module.registerHooks !== "function") {
    throw new Error(
      `Loading TypeScript handlers needs Node.js >=22.15.0 for module.registerHooks, but this process is ${process.version}.`
    );
  }

  // Node ignores the inline source maps below unless this is on.
  module.setSourceMapsSupport(true);

  // The project tsconfig sets `moduleResolution: "bundler"`, `allowJs` and may
  // set `paths`/`baseUrl`, none of which Node's resolver knows about. Node
  // still goes first, so packages resolve exactly as they would without us.
  const resolve = (specifier, context, nextResolve) => {
    try {
      return nextResolve(specifier, context);
    } catch (error) {
      if (context.parentURL === undefined || !context.parentURL.startsWith("file:")) {
        throw error;
      }
      const resolved = resolveTs(specifier, fileURLToPath(context.parentURL));
      if (resolved == null) {
        throw error;
      }
      return { url: pathToFileURL(resolved).href, shortCircuit: true };
    }
  };

  module.registerHooks({
    resolve(specifier, context, nextResolve) {
      const resolved = resolve(specifier, context, nextResolve);
      // `resolveJsonModule` lets TypeScript import JSON without the
      // `type: "json"` attribute Node requires.
      if (
        resolved.url.endsWith(".json") &&
        context.parentURL !== undefined &&
        TS_EXTENSION.test(context.parentURL) &&
        context.importAttributes?.type === undefined
      ) {
        return {
          ...resolved,
          importAttributes: { ...context.importAttributes, type: "json" },
          shortCircuit: true,
        };
      }
      return resolved;
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

      const { code, map, hasModuleSyntax } = transformTs(path, readFileSync(path, "utf8"));
      return {
        format:
          extension[1] === "m"
            ? "module"
            : extension[1] === "c"
              ? "commonjs"
              : hasModuleSyntax
                ? "module"
                : packageType(path),
        source: map ? code + inlineSourceMap(map) : code,
        shortCircuit: true,
      };
    },
  });
};
