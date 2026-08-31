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
  if (typeof timeoutMs !== "number" || timeoutMs <= 0) {
    throw new Error(
      `Resolver '${name}' requires a positive \`timeoutMs\`. The resolver process connects ` +
        `around PgBouncer, so statement_timeout is the only bound on a runaway query.`
    );
  }
  if (registry.some((r) => r.name === name)) {
    throw new Error(`Resolver '${name}' is declared more than once`);
  }

  const resolver = {
    name,
    description: options.description,
    args: options.args ?? {},
    output,
    admin: options.admin === true,
    cacheTtlMs: options.cacheTtlMs ?? 0,
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
