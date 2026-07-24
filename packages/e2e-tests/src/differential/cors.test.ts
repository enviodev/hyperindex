/**
 * CORS parity: `envio serve` must reproduce Hasura's default (permissive)
 * CORS behavior header-for-header. Runs the same probes against real Hasura
 * (8080) and a `serve` instance spawned by the suite, and asserts the
 * cross-origin response headers match.
 *
 * Requires Postgres (5433) and Hasura (8080) — the same services the other
 * differential tests use.
 */

import { describe, it, expect, beforeAll, afterAll } from "vitest";
import { phaseConfigs } from "./corpus.js";
import { applyFixture, trackDatabase } from "./hasuraSetup.js";
import { hasuraUrl, serveUrl } from "./env.js";
import { startServe, stopServe, type ServeProcess } from "./serveProcess.js";

const fixtureDir = new URL("../../fixtures/differential/", import.meta.url);

const CORS_HEADERS = [
  "access-control-allow-origin",
  "access-control-allow-credentials",
  "access-control-allow-methods",
  "access-control-allow-headers",
  "access-control-max-age",
  "access-control-expose-headers",
] as const;

function corsHeaders(res: Response): Record<string, string | null> {
  return Object.fromEntries(
    CORS_HEADERS.map((name) => [name, res.headers.get(name)])
  );
}

const origin = "https://app.example.com";

/** All three CORS scenarios against one endpoint, as one comparable object. */
async function probeCors(endpoint: string) {
  const url = `${endpoint}/v1/graphql`;

  const preflight = await fetch(url, {
    method: "OPTIONS",
    headers: {
      Origin: origin,
      "Access-Control-Request-Method": "POST",
      "Access-Control-Request-Headers": "content-type,x-hasura-admin-secret",
    },
  });

  const actual = await fetch(url, {
    method: "POST",
    headers: { Origin: origin, "Content-Type": "application/json" },
    body: JSON.stringify({ query: "{ __typename }" }),
  });

  const noOrigin = await fetch(url, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ query: "{ __typename }" }),
  });

  return {
    preflight: { status: preflight.status, headers: corsHeaders(preflight) },
    actual: { headers: corsHeaders(actual) },
    noOrigin: { headers: corsHeaders(noOrigin) },
  };
}

describe.sequential("cors parity", () => {
  let serve: ServeProcess;

  beforeAll(async () => {
    await applyFixture(fixtureDir);
    await trackDatabase(phaseConfigs.default);
    serve = await startServe(phaseConfigs.default);
  }, 120_000);

  afterAll(async () => {
    await stopServe(serve);
  });

  it("matches Hasura's default CORS headers", async () => {
    const [hasura, envio] = await Promise.all([
      probeCors(hasuraUrl),
      probeCors(serveUrl),
    ]);
    expect(envio).toEqual(hasura);
  });
});
