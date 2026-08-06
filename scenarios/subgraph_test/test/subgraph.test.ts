import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { createServer, type Server } from "node:http";
process.env.ENVIO_SUBGRAPH_RPC = "http://127.0.0.1:8601";

const { createTestIndexer, TestHelpers } = await import("envio");

const { Addresses } = TestHelpers;
const factory = "0x1F98431c8aD98523631AE4a59f267346ea31F984";
const pair = Addresses.mockAddresses[3];

// name() -> "Uniswap", ABI-encoded.
const NAME_RESULT =
  "0x0000000000000000000000000000000000000000000000000000000000000020" +
  "0000000000000000000000000000000000000000000000000000000000000007" +
  "556e69737761700000000000000000000000000000000000000000000000000000".slice(0, 64);

let server: Server;

beforeAll(async () => {
  server = createServer((req, res) => {
    let body = "";
    req.on("data", (chunk) => (body += chunk));
    req.on("end", () => {
      const request = JSON.parse(body);
      res.end(
        JSON.stringify({
          jsonrpc: "2.0",
          id: request.id,
          result: request.method === "eth_call" ? NAME_RESULT : "0x1",
        }),
      );
    });
  });
  await new Promise<void>((resolve) => server.listen(8601, "127.0.0.1", resolve));
});

afterAll(async () => {
  await new Promise<void>((resolve) => server.close(() => resolve()));
});

describe("an unmodified subgraph project", () => {
  it("indexes a factory event, its contract call and its template", async () => {
    const indexer = createTestIndexer();

    await indexer.process({
      chains: {
        1: {
          simulate: [
            {
              contract: "Factory",
              event: "PairCreated",
              srcAddress: factory,
              params: {
                token0: Addresses.mockAddresses[1],
                token1: Addresses.mockAddresses[2],
                pair,
              },
            },
          ],
        },
      },
    });

    expect(await indexer.Pair.getOrThrow(pair.toLowerCase())).toEqual({
      id: pair.toLowerCase(),
      token0: Addresses.mockAddresses[1].toLowerCase(),
      token1: Addresses.mockAddresses[2].toLowerCase(),
      name: "Uniswap",
    });
  });
});
