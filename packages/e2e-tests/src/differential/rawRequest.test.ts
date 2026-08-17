/**
 * The transport probes' own guard. `envio serve` compresses nothing today,
 * so the compression branch of the probe machinery is never exercised by
 * the corpus — and a probe that silently failed to notice `content-encoding`
 * would report the gzip cases as a known gap forever, including after the
 * gap closed.
 *
 * Needs no Postgres, Hasura or serve: the peer is a throwaway http server.
 */

import { describe, it, expect, beforeAll, afterAll } from "vitest";
import { createServer, type Server } from "node:http";
import { gzipSync } from "node:zlib";
import { rawRequest, decodeBody } from "./rawRequest.js";

// Large enough that gzip's framing overhead cannot exceed what it saves,
// like a real list response.
const PAYLOAD = JSON.stringify({
  data: {
    User: Array.from({ length: 50 }, (_, i) => ({
      id: `user-${i}`,
      address: `0xaaaa00000000000000000000000000000000${String(i).padStart(4, "0")}`,
    })),
  },
});

let server: Server;
let baseUrl: string;

beforeAll(async () => {
  server = createServer((req, res) => {
    if (req.url === "/gzip") {
      res.writeHead(200, {
        "content-type": "application/json",
        "content-encoding": "gzip",
        vary: "Accept-Encoding",
      });
      res.end(gzipSync(Buffer.from(PAYLOAD)));
      return;
    }
    if (req.url === "/lying") {
      // Announces gzip, sends plain text.
      res.writeHead(200, { "content-encoding": "gzip" });
      res.end(PAYLOAD);
      return;
    }
    res.writeHead(200, { "content-type": "application/json" });
    res.end(PAYLOAD);
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const address = server.address();
  if (address === null || typeof address === "string")
    throw new Error("probe server did not bind a port");
  baseUrl = `http://127.0.0.1:${address.port}`;
});

afterAll(async () => {
  await new Promise<void>((resolve, reject) =>
    server.close((err) => (err ? reject(err) : resolve()))
  );
});

describe("transport probe machinery", () => {
  it("sees a compressed response as compressed and decodes it", async () => {
    const response = await rawRequest(baseUrl, {
      method: "GET",
      path: "/gzip",
      headers: { "Accept-Encoding": "gzip" },
    });
    expect({
      status: response.status,
      contentEncoding: response.headers["content-encoding"] ?? null,
      vary: response.headers["vary"] ?? null,
      compressedIsSmaller: response.raw.length < PAYLOAD.length,
      body: decodeBody(response),
    }).toEqual({
      status: 200,
      contentEncoding: "gzip",
      vary: "Accept-Encoding",
      compressedIsSmaller: true,
      body: PAYLOAD,
    });
  });

  it("sends no accept-encoding of its own and reports an identity body", async () => {
    const response = await rawRequest(baseUrl, { method: "GET", path: "/" });
    expect({
      contentEncoding: response.headers["content-encoding"] ?? null,
      body: decodeBody(response),
    }).toEqual({ contentEncoding: null, body: PAYLOAD });
  });

  it("fails loudly when an announced encoding was not applied", async () => {
    const response = await rawRequest(baseUrl, { method: "GET", path: "/lying" });
    expect(() => decodeBody(response)).toThrow();
  });
});
