// The user-facing resolver API.
//
// Declaring a resolver registers it, the same way importing a handler module
// registers its handlers. `envio resolvers manifest` imports the project's
// resolver module and reads the registry back out; the runtime reads the same
// registry to dispatch. One registration, two consumers, no separate export
// list for the user to keep in sync.

import { buildManifest, toSDL } from "./manifest.js";

export { ResolverError } from "./errors.js";

export {
  buildManifest,
  defineEnum,
  defineInput,
  defineScalar,
  defineType,
  toSDL,
  SCHEMA_VERSION,
} from "./manifest.js";

const registry = [];

/**
 * Declares a custom GraphQL resolver.
 *
 * Validation happens here rather than at manifest time so the error points at
 * the declaration that caused it, while the stack still says which file it
 * came from.
 */
export function createResolver(options) {
  if (!options || typeof options !== "object") {
    throw new Error("createResolver expects an options object");
  }
  const { name, output, handler, timeoutMs } = options;

  if (typeof name !== "string" || name.length === 0) {
    throw new Error("createResolver requires a non-empty `name`");
  }
  if (!output || typeof output.t === "undefined") {
    throw new Error(
      `Resolver '${name}' requires an \`output\` schema, e.g. output: S.array(MyType)`
    );
  }
  if (typeof handler !== "function") {
    throw new Error(`Resolver '${name}' requires a \`handler\` function`);
  }
  if (options.maxBlocksBehind !== undefined) {
    const whole = (value) =>
      typeof value === "number" && Number.isSafeInteger(value) && value >= 0;
    const limit = options.maxBlocksBehind;
    const ok =
      whole(limit) ||
      (typeof limit === "object" &&
        limit !== null &&
        !Array.isArray(limit) &&
        Object.keys(limit).length > 0 &&
        Object.entries(limit).every(([chainId, value]) => whole(Number(chainId)) && whole(value)));
    if (!ok) {
      throw new Error(
        `Resolver '${name}' has an invalid \`maxBlocksBehind\`. It is how far behind head this resolver will still answer, so it is either a whole number of blocks applying to every chain, or an object of chainId to blocks naming the chains it cares about.`
      );
    }
  }
  if (typeof timeoutMs !== "number" || timeoutMs <= 0) {
    throw new Error(
      `Resolver '${name}' requires a positive \`timeoutMs\`. It becomes the statement_timeout on every query the resolver makes, which is the only thing bounding a runaway one.`
    );
  }
  if (registry.some((r) => r.name === name)) {
    throw new Error(`Resolver '${name}' is declared more than once`);
  }

  const resolver = {
    name,
    // Passed through so `buildManifest` below refuses it with a message that
    // names the resolver, rather than it being silently dropped here.
    cacheTtlMs: options.cacheTtlMs,
    description: options.description,
    args: options.args ?? {},
    output,
    // `admin` is the old spelling. It named a Hasura role that is no longer how
    // these are reached, so `private` is the name now; both mean the same
    // thing -- off the public schema unless the caller presents a key.
    private: options.private === true || options.admin === true,
    maxBlocksBehind: options.maxBlocksBehind,
    timeoutMs,
    handler,
  };
  // Built before registering, not after: a declaration whose schemas cannot
  // be represented in GraphQL must leave the registry untouched, or the
  // failure follows every later build. Doing it here at all is what surfaces
  // the problem at the declaration rather than at the end of codegen, where
  // the stack no longer says which resolver was at fault.
  buildManifest([resolver]);

  registry.push(resolver);
  return resolver;
}

/** Every resolver declared so far, in declaration order. */
export function getRegisteredResolvers() {
  return [...registry];
}

/** Test-only: forgets every declaration. */
export function resetResolvers() {
  registry.length = 0;
}

/** The manifest and SDL for everything declared so far. */
export function buildRegisteredManifest() {
  const manifest = buildManifest(registry);
  return { manifest, sdl: toSDL(manifest) };
}
