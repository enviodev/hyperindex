/**
 * Minimal raw HTTP client for transport-level parity probes.
 *
 * `fetch` is unusable here: it negotiates `accept-encoding` itself and
 * transparently decodes the response, so a probe cannot tell whether the
 * server actually compressed the body. `node:http` decodes the transfer
 * encoding only, leaving `content-encoding` and the response bytes exactly
 * as they arrived.
 */

import { request } from "node:http";
import { gunzipSync, inflateSync, brotliDecompressSync } from "node:zlib";

export interface RawResponse {
  status: number;
  headers: Record<string, string>;
  /** Body exactly as it arrived — still compressed if content-encoding is set. */
  raw: Buffer;
}

export interface RawRequestOptions {
  method: string;
  /** Path including any query string, e.g. `/v1/graphql?query=%7B__typename%7D`. */
  path: string;
  headers?: Record<string, string>;
  body?: string;
}

function headerRecord(
  headers: Record<string, string | string[] | undefined>
): Record<string, string> {
  return Object.fromEntries(
    Object.entries(headers).map(([name, value]) => [
      name.toLowerCase(),
      Array.isArray(value) ? value.join(", ") : (value ?? ""),
    ])
  );
}

export function rawRequest(
  baseUrl: string,
  options: RawRequestOptions
): Promise<RawResponse> {
  const url = new URL(baseUrl);
  return new Promise((resolve, reject) => {
    const req = request(
      {
        host: url.hostname,
        port: url.port,
        method: options.method,
        path: options.path,
        headers: options.headers,
      },
      (res) => {
        const chunks: Buffer[] = [];
        res.on("data", (chunk: Buffer) => chunks.push(chunk));
        res.on("end", () =>
          resolve({
            status: res.statusCode ?? 0,
            headers: headerRecord(res.headers),
            raw: Buffer.concat(chunks),
          })
        );
        res.on("error", reject);
      }
    );
    req.on("error", reject);
    // A successful WebSocket handshake answers 101 and hands over the
    // socket, so no 'response' ever fires. Capture the handshake result and
    // drop the connection — the subscription protocol itself is covered by
    // subscriptions.test.ts.
    req.on("upgrade", (res, socket) => {
      socket.destroy();
      resolve({
        status: res.statusCode ?? 0,
        headers: headerRecord(res.headers),
        raw: Buffer.alloc(0),
      });
    });
    if (options.body !== undefined) req.write(options.body);
    req.end();
  });
}

/**
 * Decodes a response body per its `content-encoding`. An encoding the
 * server announced but did not actually apply surfaces as a thrown decode
 * error rather than a silently mismatched body.
 */
export function decodeBody(response: RawResponse): string {
  const encoding = response.headers["content-encoding"];
  switch (encoding) {
    case undefined:
    case "":
    case "identity":
      return response.raw.toString("utf8");
    case "gzip":
      return gunzipSync(response.raw).toString("utf8");
    case "deflate":
      return inflateSync(response.raw).toString("utf8");
    case "br":
      return brotliDecompressSync(response.raw).toString("utf8");
    default:
      throw new Error(`Unsupported content-encoding: ${encoding}`);
  }
}
