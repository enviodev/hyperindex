import module from "node:module";
import { readFileSync, statSync } from "node:fs";
import { fileURLToPath, pathToFileURL } from "node:url";
import { dirname, extname, isAbsolute, join, parse as parsePath, posix, sep } from "node:path";

const TS_EXTENSION = /\.([cm]?)tsx?$/;
const TS_PARENT = /\.([cm]?ts|tsx)($|\?)/;
const JSON_URL = /\.json($|\?)/;
const DIRECTORY_SPECIFIER = /\/(?:$|\?)/;
const NOT_FOUND_CODES = new Set(["ERR_MODULE_NOT_FOUND", "ERR_PACKAGE_PATH_NOT_EXPORTED"]);
const CJS_NOT_FOUND_CODES = new Set(["MODULE_NOT_FOUND", "ERR_PACKAGE_PATH_NOT_EXPORTED"]);
const DEPENDENCY_PATH = `${sep}node_modules${sep}`;

// Resolution follows tsx's ESM resolver, step for step, so handlers that ran
// under tsx resolve the same files. `.jsx` is left out because the load hook
// doesn't transform JSX.
const IMPLICIT_EXTENSIONS = {
  ".js": [".ts", ".tsx", ".js"],
  ".cjs": [".cts"],
  ".mjs": [".mts"],
};
const PROJECT_EXTENSIONS = [".ts", ".tsx", ".js", ".json"];
const DEPENDENCY_EXTENSIONS = [".js", ".json", ".ts", ".tsx"];

const isFile = (path) => {
  try {
    return statSync(path).isFile();
  } catch {
    return false;
  }
};

const readJson = (path) => {
  try {
    return JSON.parse(readFileSync(path, "utf8"));
  } catch {
    return undefined;
  }
};

const isRelativePath = (specifier) =>
  specifier[0] === "." && (specifier[1] === "/" || specifier[1] === "." || specifier[2] === "/");

const isFilePath = (specifier) => isRelativePath(specifier) || isAbsolute(specifier);

// A relative, absolute or URL specifier, which `paths` never applies to.
const isPathLike = (specifier) => {
  if (isFilePath(specifier)) return true;
  const colon = specifier.indexOf(":");
  return colon > 0 && specifier.slice(0, colon) !== "node";
};

const extensionCandidates = (url) => {
  const [path, query] = url.split("?");
  const suffix = query ? `?${query}` : "";
  const candidates = [];
  const extension = extname(path);
  const implicit = IMPLICIT_EXTENSIONS[extension];
  if (implicit) {
    const base = path.slice(0, -extension.length);
    candidates.push(...implicit.map((replacement) => base + replacement + suffix));
  }
  const fromDependency =
    !(url.startsWith("file://") || isFilePath(path)) ||
    path.includes(`${sep}node_modules${sep}`) ||
    path.includes("/node_modules/");
  const appended = fromDependency ? DEPENDENCY_EXTENSIONS : PROJECT_EXTENSIONS;
  candidates.push(...appended.map((added) => path + added + suffix));
  return candidates;
};

const missingPathFromNotFound = (error) => {
  if (error.url) return error.url;
  const missingModule = error.message.match(/^Cannot find module '([^']+)'/);
  if (missingModule) return missingModule[1];
  const missingPackage = error.message.match(/^Cannot find package '([^']+)'/);
  if (missingPackage === null) return undefined;
  const [, path] = missingPackage;
  if (!isAbsolute(path)) return undefined;
  const url = pathToFileURL(path);
  if (url.pathname.endsWith("/")) url.pathname += "package.json";
  if (!url.pathname.endsWith("/package.json")) return url.toString();
  const main = readJson(fileURLToPath(url))?.main;
  return main ? new URL(main, url).toString() : undefined;
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
      return readJson(manifest)?.type === "module" ? "module" : "commonjs";
    }
    if (directory === root) return "commonjs";
    directory = dirname(directory);
  }
};

const inlineSourceMap = (map) =>
  `\n//# sourceMappingURL=data:application/json;base64,${Buffer.from(map).toString("base64")}`;

let registered = false;

export const register = (transformTs, tsPathCandidates, allowJs) => {
  if (registered) return;
  registered = true;

  if (typeof module.registerHooks !== "function") {
    throw new Error(
      `Loading TypeScript handlers needs Node.js >=22.15.0 for module.registerHooks, but this process is ${process.version}.`
    );
  }

  // Node ignores the inline source maps below unless this is on.
  module.setSourceMapsSupport(true);

  const resolveExtensions = (url, context, nextResolve, throwError = false) => {
    let lastError;
    for (const candidate of extensionCandidates(url)) {
      try {
        return nextResolve(candidate, context);
      } catch (error) {
        if (!NOT_FOUND_CODES.has(error?.code)) throw error;
        lastError = error;
      }
    }
    if (throwError) throw lastError;
    return undefined;
  };

  const resolveBase = (specifier, context, nextResolve) => {
    if (
      (specifier.startsWith("file://") || isRelativePath(specifier)) &&
      (TS_PARENT.test(context.parentURL) || allowJs)
    ) {
      const resolved = resolveExtensions(specifier, context, nextResolve);
      if (resolved) return resolved;
    }
    try {
      return nextResolve(specifier, context);
    } catch (error) {
      if (error?.code === "ERR_MODULE_NOT_FOUND") {
        const missing = missingPathFromNotFound(error);
        const resolved = missing && resolveExtensions(missing, context, nextResolve);
        if (resolved) return resolved;
      }
      throw error;
    }
  };

  const resolveDirectory = (specifier, context, nextResolve) => {
    if (specifier === "." || specifier === ".." || specifier.endsWith("/..")) {
      specifier += "/";
    }
    if (DIRECTORY_SPECIFIER.test(specifier)) {
      const url = new URL(specifier, context.parentURL);
      url.pathname = posix.join(url.pathname, "index");
      return resolveExtensions(url.toString(), context, nextResolve, true);
    }
    try {
      return resolveBase(specifier, context, nextResolve);
    } catch (error) {
      const missing = error?.code === "ERR_UNSUPPORTED_DIR_IMPORT" && missingPathFromNotFound(error);
      if (!missing) throw error;
      try {
        return resolveExtensions(`${missing}/index`, context, nextResolve, true);
      } catch (indexError) {
        const { message } = indexError;
        indexError.message = message.replace(`${sep}index'`, "'");
        indexError.stack = indexError.stack.replace(message, indexError.message);
        throw indexError;
      }
    }
  };

  // tsconfig `paths`/`baseUrl` take precedence over packages, except for
  // imports from dependencies.
  const resolveTsPaths = (specifier, context, nextResolve) => {
    if (!isPathLike(specifier) && !context.parentURL?.includes("/node_modules/")) {
      for (const candidate of tsPathCandidates(specifier)) {
        try {
          return resolveDirectory(pathToFileURL(candidate).toString(), context, nextResolve);
        } catch {}
      }
    }
    return resolveDirectory(specifier, context, nextResolve);
  };

  // Sync hooks also see `require()`, including the one Node makes to find the
  // named exports of a CommonJS module imported from ESM. tsx resolves those
  // with its CommonJS resolver, which differs from the ESM one, and a
  // CommonJS miss is `MODULE_NOT_FOUND` rather than `ERR_MODULE_NOT_FOUND`.
  const resolveCjs = (specifier, context, nextResolve) => {
    const parentPath = context.parentURL?.startsWith("file:")
      ? fileURLToPath(context.parentURL)
      : undefined;
    const fromTs = parentPath !== undefined && TS_PARENT.test(parentPath);
    const next = (request) => nextResolve(request, context);

    const tryExtensions = (request) => {
      if (DIRECTORY_SPECIFIER.test(request) || (!fromTs && !allowJs)) return undefined;
      for (const candidate of extensionCandidates(request)) {
        try {
          return next(candidate);
        } catch (error) {
          if (!CJS_NOT_FOUND_CODES.has(error?.code)) throw error;
        }
      }
      return undefined;
    };

    const resolveExtensionsCjs = (request) => {
      if (isFilePath(request)) {
        const resolved = tryExtensions(request);
        if (resolved) return resolved;
      }
      try {
        return next(request);
      } catch (error) {
        if (error?.code !== "MODULE_NOT_FOUND") throw error;
        if (error.path) {
          const missing =
            error.message.match(/^Cannot find module '([^']+)'$/) ??
            error.message.match(
              /^Cannot find module '([^']+)'. Please verify that the package.json has a valid "main" entry$/
            );
          const resolved = missing && tryExtensions(missing[1]);
          if (resolved) return resolved;
        }
        const resolved = tryExtensions(request);
        if (resolved) return resolved;
        throw error;
      }
    };

    const resolveIndex = (request) => {
      if (request === "." || request === ".." || request.endsWith("/..")) request += "/";
      if (DIRECTORY_SPECIFIER.test(request)) {
        let index = join(request, "index.js");
        if (request.startsWith("./")) index = `./${index}`;
        try {
          return resolveExtensionsCjs(index);
        } catch {}
      }
      try {
        return resolveExtensionsCjs(request);
      } catch (error) {
        if (error?.code === "MODULE_NOT_FOUND") {
          try {
            return resolveExtensionsCjs(`${request}${sep}index.js`);
          } catch {}
        }
        throw error;
      }
    };

    const request = specifier.startsWith("file://") ? fileURLToPath(specifier) : specifier;
    if (!isFilePath(request) && !parentPath?.includes(DEPENDENCY_PATH)) {
      for (const candidate of tsPathCandidates(request)) {
        try {
          return resolveIndex(candidate);
        } catch {}
      }
    }
    return resolveIndex(request);
  };

  module.registerHooks({
    resolve(specifier, context, nextResolve) {
      if (specifier.startsWith("node:")) {
        return nextResolve(specifier, context);
      }
      if (context.conditions?.includes("require")) {
        return { ...resolveCjs(specifier, context, nextResolve), shortCircuit: true };
      }
      const [path, query] = specifier.split("?");
      const resolved = resolveTsPaths(path, context, nextResolve);
      const url = query ? `${resolved.url}?${query}` : resolved.url;
      // TypeScript's `resolveJsonModule` imports JSON without the
      // `type: "json"` attribute Node requires.
      if (JSON_URL.test(url) && context.importAttributes?.type === undefined) {
        return {
          ...resolved,
          url,
          importAttributes: { ...context.importAttributes, type: "json" },
          shortCircuit: true,
        };
      }
      return { ...resolved, url, shortCircuit: true };
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
