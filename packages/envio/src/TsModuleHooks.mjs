import module from "node:module";
import { fileURLToPath } from "node:url";
import { unsupportedNodeMessage } from "./NodeVersion.mjs";

const TS_URL = /\.[cm]?tsx?$/;
const JSON_URL = /\.json($|\?)/;
const NOT_FOUND_CODES = new Set([
  "ERR_MODULE_NOT_FOUND",
  "ERR_PACKAGE_PATH_NOT_EXPORTED",
  "ERR_UNSUPPORTED_DIR_IMPORT",
]);

let registered = false;

// Node's own resolver still resolves every candidate the addon offers, so
// package exports and conditions behave as they do without the hooks.
export const register = (addon) => {
  if (registered) return;
  registered = true;

  // The CLI checks this first thing; a test indexer gets here without it.
  const unsupported = unsupportedNodeMessage();
  if (unsupported !== undefined) throw new Error(unsupported);

  // Node ignores the source maps `loadTs` inlines unless this is on.
  module.setSourceMapsSupport(true);

  // What legacy decorators lower to; tslib's `__decorate`, `__param` and
  // `__metadata`.
  const helpers = (globalThis.babelHelpers ??= {});
  // A function rather than an arrow: the argument count tells a class
  // decorator from a member's.
  helpers.decorate ??= function (decorators, target, key, descriptor) {
    const argumentCount = arguments.length;
    let result =
      argumentCount < 3
        ? target
        : descriptor === null
          ? (descriptor = Object.getOwnPropertyDescriptor(target, key))
          : descriptor;
    for (let index = decorators.length - 1; index >= 0; index--) {
      const decorator = decorators[index];
      if (decorator) {
        result =
          (argumentCount < 3
            ? decorator(result)
            : argumentCount > 3
              ? decorator(target, key, result)
              : decorator(target, key)) || result;
      }
    }
    if (argumentCount > 3 && result) Object.defineProperty(target, key, result);
    return result;
  };
  helpers.decorateParam ??= (index, decorator) => (target, key) => decorator(target, key, index);
  helpers.decorateMetadata ??= (key, value) =>
    typeof Reflect === "object" && typeof Reflect.metadata === "function"
      ? Reflect.metadata(key, value)
      : undefined;

  const firstResolved = (candidates, context, nextResolve) => {
    for (const candidate of candidates) {
      try {
        return nextResolve(candidate, context);
      } catch (error) {
        if (!NOT_FOUND_CODES.has(error?.code)) throw error;
      }
    }
    return undefined;
  };

  module.registerHooks({
    resolve(specifier, context, nextResolve) {
      // Handlers are ES modules, so `require()` only comes from dependencies,
      // including the one Node makes to read a CommonJS module's named
      // exports. It resolves as it would without the hooks.
      if (specifier.startsWith("node:") || context.conditions?.includes("require")) {
        return nextResolve(specifier, context);
      }
      const [path, query] = specifier.split("?");
      let resolved = firstResolved(
        addon.tsResolveCandidates(path, context.parentURL ?? null),
        context,
        nextResolve
      );
      if (resolved === undefined) {
        try {
          resolved = nextResolve(path, context);
        } catch (error) {
          resolved =
            NOT_FOUND_CODES.has(error?.code) &&
            firstResolved(
              addon.tsNotFoundCandidates(error.code, error.url ?? null, error.message),
              context,
              nextResolve
            );
          if (!resolved) throw error;
        }
      }
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
      if (!url.startsWith("file:") || !TS_URL.test(new URL(url).pathname)) {
        return nextLoad(url, context);
      }
      return { format: "module", source: addon.loadTs(fileURLToPath(url)), shortCircuit: true };
    },
  });
};
