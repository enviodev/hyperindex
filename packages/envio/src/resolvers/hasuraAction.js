// Hasura's action contract, translated to and from the dispatcher's.
//
// The two differ in the ways that matter to a client. Hasura splices the
// response body straight in as the field's value, so a result is returned bare
// rather than under `data`, and a failure is a status code rather than an
// `errors` array -- a 200 is taken as success whatever the body says.
//
// Pure, so the mapping is testable without a socket; `server.js` does the I/O.

// Hasura documents 4xx as *the* way a handler reports failure. A 5xx risks
// being reported as an unreachable webhook instead of the message below, so a
// resolver's intended status travels in `extensions.http.status` and every
// error leaves here as a 4xx.
const STATUS_BY_CODE = {
  BAD_REQUEST: 400,
  BAD_USER_INPUT: 400,
  FORBIDDEN: 403,
  RESOLVER_NOT_FOUND: 404,
};

const DEFAULT_ERROR_STATUS = 400;

import { selectionFromRequestQuery } from "./graphqlSelection.js";

const isPlainObject = (value) =>
  typeof value === "object" && value !== null && !Array.isArray(value);

/**
 * Validates a decoded action payload.
 * Returns null when it is well formed.
 */
export function badActionRequest(payload) {
  if (!isPlainObject(payload)) {
    return "expected a JSON object";
  }
  if (!isPlainObject(payload.action) || typeof payload.action.name !== "string" || payload.action.name.length === 0) {
    return "`action.name` must be a non-empty string";
  }
  if (payload.input !== undefined && !isPlainObject(payload.input)) {
    return "`input` must be an object";
  }
  if (payload.session_variables !== undefined && !isPlainObject(payload.session_variables)) {
    return "`session_variables` must be an object";
  }
  return null;
}

/**
 * Turns a validated action payload into the dispatcher's request.
 *
 * `requestId` is minted by the caller: Hasura sends none, and without one a
 * failure in the logs cannot be tied back to the request that caused it.
 */
export function toResolveRequest(payload, requestId) {
  const role = payload.session_variables?.["x-hasura-role"];
  return {
    field: payload.action.name,
    args: payload.input ?? {},
    selection: selectionFromRequestQuery(payload.request_query, payload.action.name),
    // Hasura roles are arbitrary strings, and the dispatcher's are not. Only
    // `admin` grants admin, so an unrecognised role is treated as public
    // rather than rejected -- the same answer an anonymous caller would get.
    role: role === "admin" ? "admin" : "public",
    requestId,
  };
}

/** Turns a dispatcher answer into the status and body Hasura expects. */
export function toActionResponse(answer) {
  const failure = answer.errors?.[0];
  if (failure !== undefined) {
    const extensions = failure.extensions ?? {};
    return {
      status: STATUS_BY_CODE[extensions.code] ?? DEFAULT_ERROR_STATUS,
      body: { message: failure.message, extensions },
    };
  }
  return { status: 200, body: answer.data ?? null };
}

/** The error body for a request that never reached the dispatcher. */
export function actionErrorBody(message, code) {
  return { message, extensions: { code } };
}
