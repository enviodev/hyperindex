const ISSUES_URL = "https://github.com/enviodev/hyperindex/issues";

/** A feature we recognise and deliberately don't implement. */
export function unsupported(feature: string, location: string): Error {
  return new Error(
    `Envio Subgraph doesn't support ${feature} yet.\n` +
      `  Found in ${location}.\n` +
      `First, make sure you're on the latest envio version — support may have landed:\n` +
      `  pnpm add -D envio@latest\n` +
      `If you're up to date and need this feature, please open an issue (existing\n` +
      `issues welcome a 👍 — demand drives prioritization):\n  ${ISSUES_URL}`,
  );
}

/** Something we don't recognise at all: newer than us, or a typo. */
export function unknown(thing: string, location: string): Error {
  return new Error(
    `Envio Subgraph doesn't know ${thing}.\n` +
      `  Found in ${location}.\n` +
      `This may be a feature newer than this envio version understands, or a typo.\n` +
      `First, make sure you're on the latest envio version:\n` +
      `  pnpm add -D envio@latest\n` +
      `If you're up to date and this is a real subgraph feature, please open an\n` +
      `issue so we can add it: ${ISSUES_URL}`,
  );
}

/**
 * Names a trap must answer for rather than refuse. AS-compiled mappings never
 * feature-detect, so nothing legitimate reaches these — but `console.log`,
 * `await` and `JSON.stringify` do, and they must not explode.
 */
const PASSTHROUGH = new Set([
  "then",
  "toJSON",
  "constructor",
  "valueOf",
  "toString",
  "inspect",
  "nodeType",
  "$$typeof",
  "@@__IMMUTABLE_ITERABLE__@@",
]);

function isPassthrough(prop: PropertyKey): boolean {
  return typeof prop === "symbol" || PASSTHROUGH.has(prop as string);
}

/**
 * Full Proxy for a graph-ts namespace object. Future graph-ts APIs are
 * unenumerable, so only a `get` trap can catch them; these are cold paths, so
 * the trap cost doesn't matter.
 */
export function strictNamespace<T extends object>(name: string, target: T): T {
  return new Proxy(target, {
    get(target, prop, receiver) {
      if (prop in target || isPassthrough(prop)) {
        return Reflect.get(target, prop, receiver);
      }
      throw unknown(`the graph-ts API ${name}.${String(prop)}`, `a mapping handler`);
    },
  });
}

/**
 * Base of a hot class's prototype chain: instance -> real prototype with every
 * known member as a plain property (V8-optimizable) -> this Proxy. Known
 * lookups never reach the trap; unknown names fall through it and throw.
 */
export function strictPrototypeTail(className: string): object {
  return new Proxy(Object.create(null), {
    get(_target, prop) {
      if (isPassthrough(prop)) {
        return undefined;
      }
      throw unknown(`the ${className} member ${String(prop)}`, `a mapping handler`);
    },
  });
}

/** A known-but-refused field: enumerable, so a plain throwing getter is enough. */
export function refusedGetter(object: object, prop: string, feature: string, location: string) {
  Object.defineProperty(object, prop, {
    enumerable: true,
    configurable: true,
    get() {
      throw unsupported(feature, location);
    },
  });
}
