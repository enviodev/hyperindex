// The HTTP surface of the resolver process: one POST per caller -- Hasura's
// action contract and envio-serve's -- and the two probes an orchestrator
// restarts and routes on.
//
// Deliberately not a framework. The whole surface is three routes and a JSON
// body with a size cap, and the one thing that must not drift is the wire
// contract, which is easier to read as bytes in and bytes out.

import { createServer } from "node:http";
import { randomUUID } from "node:crypto";
import { createDispatcher } from "./dispatch.js";
import {
  actionErrorBody,
  badActionRequest,
  toActionResponse,
  toResolveRequest,
} from "./hasuraAction.js";
import { error as logError } from "../Logging.res.mjs";
import { Resolvers as ResolversEnv } from "../Env.res.mjs";

// Serve coerces arguments before dispatching, so a request is small by
// construction. The cap is here because the socket is reachable by whatever
// shares its network, not because a legitimate request could approach it.
const MAX_REQUEST_BYTES = 1024 * 1024;

function readBody(request, limit) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    request.on("data", (chunk) => {
      size += chunk.length;
      if (size > limit) {
        reject(new Error(`Request body exceeds ${limit} bytes`));
        request.destroy();
        return;
      }
      chunks.push(chunk);
    });
    request.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
    request.on("error", reject);
  });
}

function send(response, status, body) {
  const payload = JSON.stringify(body);
  response.writeHead(status, {
    "content-type": "application/json",
    "content-length": Buffer.byteLength(payload),
  });
  response.end(payload);
}

const wireError = (message, code) => ({
  errors: [{ message, extensions: { code } }],
});

/**
 * Starts the resolver process's HTTP server.
 *
 * Resolves once the socket is listening, with the port it bound — pass
 * `port: 0` to let the OS choose one.
 */
export async function startResolverServer(options) {
  const { resolvers, pool, exposeErrors = false, checkCompatible } = options;
  const port = options.port ?? ResolversEnv.port();
  const host = options.host ?? "0.0.0.0";

  const dispatch = createDispatcher({
    resolvers,
    pool,
    exposeErrors,
    onError:
      options.onError ??
      ((error, context) =>
        logError(
          `Resolver '${context.field}' failed (requestId ${context.requestId}): ${
            error?.stack ?? error
          }`
        )),
  });

  const server = createServer((request, response) => {
    const path = (request.url ?? "").split("?")[0];

    if (request.method === "GET" && path === "/healthz") {
      send(response, 200, { status: "ok" });
      return;
    }

    if (request.method === "GET" && path === "/readyz") {
      // Ready means the database answers and is the one this build indexes,
      // not merely that the process is up: a resolver process that cannot
      // reach Postgres has nothing to serve, and one pointed at a database
      // indexed by a different build would answer with plausible wrong
      // numbers.
      pool
        .forResolver({ name: "readyz", timeoutMs: 2_000 })
        .sql.unsafe("SELECT 1;")
        .then(async () => (checkCompatible ? await checkCompatible() : null))
        .then((reason) =>
          reason == null
            ? send(response, 200, { status: "ok" })
            : send(response, 503, { status: "incompatible", reason })
        )
        .catch((error) => {
          send(response, 503, { status: "unavailable", reason: error.message });
        });
      return;
    }

    const isServe = request.method === "POST" && path === "/resolve";
    const isAction = request.method === "POST" && path === "/hasura-action";

    if (!isServe && !isAction) {
      send(response, 404, wireError(`No route for ${request.method} ${path}`, "NOT_FOUND"));
      return;
    }

    readBody(request, MAX_REQUEST_BYTES)
      .then(async (raw) => {
        let parsed;
        try {
          parsed = JSON.parse(raw);
        } catch {
          if (isAction) {
            send(response, 400, actionErrorBody("Request body is not valid JSON", "BAD_REQUEST"));
          } else {
            send(response, 400, wireError("Request body is not valid JSON", "BAD_REQUEST"));
          }
          return;
        }

        if (isAction) {
          const invalid = badActionRequest(parsed);
          if (invalid !== null) {
            send(
              response,
              400,
              actionErrorBody(`Malformed action request: ${invalid}`, "BAD_REQUEST")
            );
            return;
          }
          const answer = await dispatch(toResolveRequest(parsed, randomUUID()));
          const { status, body } = toActionResponse(answer);
          send(response, status, body);
          return;
        }

        const answer = await dispatch(parsed);
        // A malformed request is the caller's error and says so in the status;
        // everything a resolver itself produces is a 200 with a GraphQL-shaped
        // body, because the operation as a whole still succeeded.
        const isBadRequest =
          answer.errors?.[0]?.extensions?.code === "BAD_REQUEST";
        send(response, isBadRequest ? 400 : 200, answer);
      })
      .catch((error) => {
        if (isAction) {
          send(response, 400, actionErrorBody(error.message, "BAD_REQUEST"));
        } else {
          send(response, 400, wireError(error.message, "BAD_REQUEST"));
        }
      });
  });

  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(port, host, () => {
      server.removeListener("error", reject);
      resolve();
    });
  });

  return {
    port: server.address().port,
    close: () =>
      new Promise((resolve, reject) =>
        server.close((error) => (error ? reject(error) : resolve()))
      ),
  };
}
