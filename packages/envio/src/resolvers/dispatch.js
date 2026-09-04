// Turns one `/resolve` request into one response body.
//
// The wire contract is envio-serve's, which already implements and tests it:
// a request names a field, its already-coerced arguments, the selection the
// caller asked for, and the role the operation runs under; the answer is
// `{ data }` or `{ errors }`, and `errors` wins when both could apply.
//
// Two things happen here that look like validation but are not optional.
// Arguments are parsed through their declared schemas, because that is what
// turns serve's JSON into the values the handler declared -- a BigInt argument
// arrives as a string -- and what runs the user's own refinements, which serve
// cannot. Results are converted back through the output schema for the mirror
// reason: a handler returning a bigint would otherwise throw inside
// JSON.stringify, and the conversion drops anything not declared, so an
// over-fetching resolver cannot leak through even before serve projects.

import * as S from "rescript-schema";
import { unwrapNullableOutput } from "./manifest.js";
import { ResolverError } from "./errors.js";
import { PRIVATE_KEY_HEADER } from "./hasuraMetadata.js";

// Built once per resolver, from a copy: `S.schema` replaces the schema values
// in the object it is handed, which would gut the declaration the manifest is
// derived from.
const argsSchemas = new WeakMap();
const outputSchemas = new WeakMap();

function argsSchemaOf(resolver) {
  let schema = argsSchemas.get(resolver);
  if (schema === undefined) {
    schema = S.schema({ ...resolver.args });
    argsSchemas.set(resolver, schema);
  }
  return schema;
}

function outputSchemaOf(resolver) {
  let unwrapped = outputSchemas.get(resolver);
  if (unwrapped === undefined) {
    unwrapped = unwrapNullableOutput(resolver.output);
    outputSchemas.set(resolver, unwrapped);
  }
  return unwrapped;
}

function errorBody(message, code, extra) {
  return {
    errors: [{ message, extensions: { code, ...extra } }],
  };
}

const isPlainObject = (value) =>
  typeof value === "object" && value !== null && !Array.isArray(value);

/**
 * Validates a decoded request body against the wire contract.
 * Returns null when it is well formed.
 */
export function badRequest(request) {
  if (!isPlainObject(request)) {
    return "expected a JSON object";
  }
  if (typeof request.field !== "string" || request.field.length === 0) {
    return "`field` must be a non-empty string";
  }
  if (request.args !== undefined && !isPlainObject(request.args)) {
    return "`args` must be an object";
  }
  if (request.selection !== undefined && !isPlainObject(request.selection)) {
    return "`selection` must be an object";
  }
  if (request.role !== "public" && request.role !== "admin") {
    return '`role` must be "public" or "admin"';
  }
  if (typeof request.requestId !== "string") {
    return "`requestId` must be a string";
  }
  return null;
}

/**
 * Builds the dispatcher the HTTP server calls per request.
 *
 * `exposeErrors` puts an unexpected error's own message on the wire. Off by
 * default: a driver error can carry a connection string, and the caller is the
 * public internet. `envio dev` turns it on.
 */
// How long a chain-height read is reused for. Staleness is measured in blocks
// and moves at block time, so re-reading it per request would cost a query to
// learn the same answer.
const STALENESS_CACHE_MS = 2_000;

export function createDispatcher({ resolvers, pool, exposeErrors = false, onError }) {
  const byName = new Map();
  for (const resolver of resolvers) {
    byName.set(resolver.name, resolver);
  }

  let cachedHeights = { at: 0, chains: null };

  /**
   * Every chain's distance from head, or null when that cannot be read. Null
   * means "do not know", and a gate that cannot read the answer lets the
   * request through: refusing everything because the freshness probe itself
   * failed would turn one broken query into a total outage.
   */
  const chainsBehindHead = async () => {
    const now = Date.now();
    if (cachedHeights.chains !== null && now - cachedHeights.at < STALENESS_CACHE_MS) {
      return cachedHeights.chains;
    }
    try {
      const heights = await pool
        .forResolver({ name: "staleness", timeoutMs: 2_000 })
        .chainHeights();
      const chains = Object.values(heights).map((chain) => ({
        chainId: chain.chainId,
        behind: Math.max(0, chain.sourceBlock - chain.progressBlock),
      }));
      cachedHeights = { at: now, chains };
      return chains;
    } catch {
      return null;
    }
  };

  /**
   * The first chain past its limit, or null when all of them are inside it.
   *
   * A bare number applies to every chain; an object gives a limit per chain
   * and covers only the chains it names. That distinction matters on a
   * multichain indexer, because "blocks behind" is not comparable between
   * chains — a few hundred blocks is seconds on Arbitrum and hours on
   * Ethereum — and because a resolver reading one chain's tables should not be
   * refused for another chain's lag.
   */
  const chainPastLimit = (chains, limit) => {
    for (const chain of chains) {
      const cap = typeof limit === "number" ? limit : limit[chain.chainId];
      if (cap === undefined) continue;
      if (chain.behind > cap) return { ...chain, cap };
    }
    return null;
  };

  return async function dispatch(request, { privateKeyOk = false } = {}) {
    const invalid = badRequest(request);
    if (invalid !== null) {
      return errorBody(`Malformed resolve request: ${invalid}`, "BAD_REQUEST");
    }

    const { field, role } = request;
    const resolver = byName.get(field);
    if (resolver === undefined) {
      return errorBody(
        `No resolver named '${field}' is registered`,
        "RESOLVER_NOT_FOUND"
      );
    }
    // A private resolver is on the public schema so Hasura will route to it,
    // which makes this check the only thing standing in front of it. An admin
    // caller still passes: reaching here as `admin` means the shared secret was
    // presented, which an unauthenticated caller cannot do.
    if (resolver.private && !privateKeyOk && role !== "admin") {
      return errorBody(
        `Resolver '${field}' is private. Present its key in the ${PRIVATE_KEY_HEADER} header.`,
        "FORBIDDEN"
      );
    }

    let args;
    try {
      args = S.parseOrThrow(request.args ?? {}, argsSchemaOf(resolver));
    } catch (error) {
      return errorBody(
        `Invalid arguments for '${field}': ${error.message}`,
        "BAD_USER_INPUT"
      );
    }

    // After the arguments parse and before any handler runs: answering from an
    // index that is behind head is worse than not answering, because the
    // numbers look real.
    if (resolver.maxBlocksBehind !== undefined) {
      const chains = await chainsBehindHead();
      const stale = chains === null ? null : chainPastLimit(chains, resolver.maxBlocksBehind);
      if (stale !== null) {
        return errorBody(
          `Chain ${stale.chainId} is ${stale.behind} blocks behind head, past this resolver's limit of ${stale.cap}; refusing to answer from a stale index`,
          "SERVICE_UNAVAILABLE"
        );
      }
    }

    let result;
    try {
      result = await resolver.handler({
        args,
        db: pool.forResolver({ name: field, timeoutMs: resolver.timeoutMs }),
        selection: request.selection ?? {},
        ctx: {
          role,
          requestId: request.requestId,
          traceparent: request.traceparent,
        },
      });
    } catch (error) {
      if (error instanceof ResolverError) {
        return { errors: [{ message: error.message, extensions: error.toExtensions() }] };
      }
      onError?.(error, { field, requestId: request.requestId });
      return errorBody(
        exposeErrors
          ? `Resolver '${field}' failed: ${error?.message ?? String(error)}`
          : `Resolver '${field}' failed`,
        "INTERNAL_SERVER_ERROR"
      );
    }

    try {
      const { inner, nullable } = outputSchemaOf(resolver);
      if (nullable && (result === undefined || result === null)) {
        return { data: null };
      }
      return { data: S.reverseConvertToJsonOrThrow(result, inner) };
    } catch (error) {
      // Reported rather than nulled: serve's projection would make a missing
      // field read as absent, which in a dashboard is a wrong number with no
      // explanation anywhere.
      onError?.(error, { field, requestId: request.requestId });
      return errorBody(
        `Resolver '${field}' returned a result that doesn't match its declared output: ${error.message}`,
        "INVALID_RESULT"
      );
    }
  };
}
