import { afterAll, beforeAll, beforeEach, describe, expect, it } from "vitest";
import { S } from "envio";
import { createResolver, getRegisteredResolvers } from "envio/src/resolvers/index.js";
import { createResolverPoolFromEnv } from "envio/src/resolvers/db.js";
import { startResolverServer } from "envio/src/resolvers/server.js";

// The staleness gate, over real HTTP against a real server. Only the one read
// it makes is substituted: what the indexer wrote about each chain is the
// input to the decision, and a test that had to drive an indexer to a chosen
// lag could not state the cases at all.

const ARBITRUM = 42161;
const ETHEREUM = 1;

/** What `chainHeights()` will answer, and how many times it was asked. */
let heights: Record<string, unknown> = {};
let heightReads = 0;
let heightFailure: Error | null = null;
let heightDelayMs = 0;

const chain = (chainId: number, behind: number) => ({
  chainId,
  ecosystem: "evm",
  startBlock: 0,
  sourceBlock: 1_000_000,
  bufferBlock: 1_000_000,
  progressBlock: 1_000_000 - behind,
  isReady: true,
});

createResolver({
  name: "everyChain",
  output: S.string,
  timeoutMs: 5_000,
  maxBlocksBehind: 100,
  handler: async () => "answered",
});

createResolver({
  name: "namedChains",
  output: S.string,
  timeoutMs: 5_000,
  // Names Arbitrum only: a few hundred blocks is seconds there and hours on
  // Ethereum, so a limit that covered both would be wrong for one of them.
  maxBlocksBehind: { [ARBITRUM]: 100 },
  handler: async () => "answered",
});

createResolver({
  name: "ungated",
  output: S.string,
  timeoutMs: 5_000,
  handler: async () => "answered",
});

let server: Awaited<ReturnType<typeof startResolverServer>>;
let pool: ReturnType<typeof createResolverPoolFromEnv>;

const ask = async (field: string) => {
  const response = await fetch(`http://127.0.0.1:${server.port}/resolve`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ field, args: {}, selection: {}, role: "public", requestId: "r" }),
  });
  return { status: response.status, body: await response.json() };
};

beforeAll(async () => {
  pool = createResolverPoolFromEnv({ entities: {}, pgSchema: "public" });
  const counted = {
    ...pool,
    forResolver: (options: never) => ({
      ...pool.forResolver(options),
      chainHeights: async () => {
        heightReads += 1;
        await new Promise((r) => setTimeout(r, heightDelayMs));
        if (heightFailure !== null) throw heightFailure;
        return heights;
      },
    }),
  };
  server = await startResolverServer({
    resolvers: getRegisteredResolvers().filter((resolver: { name: string }) =>
      ["everyChain", "namedChains", "ungated"].includes(resolver.name)
    ),
    pool: counted as never,
    port: 0,
  });
});

afterAll(async () => {
  await server.close();
  await pool.end();
});

beforeEach(async () => {
  heightReads = 0;
  heightFailure = null;
  heightDelayMs = 0;
  // The gate caches for 2s, so each case has to outlast the one before it.
  await new Promise((resolve) => setTimeout(resolve, 2_100));
});

describe("refusing to answer from a stale index", () => {
  it("answers while every chain is inside a bare numeric limit", async () => {
    heights = { [ETHEREUM]: chain(ETHEREUM, 99), [ARBITRUM]: chain(ARBITRUM, 0) };
    expect(await ask("everyChain")).toEqual({
      status: 200,
      body: { data: "answered" },
    });
  });

  // 503, not 400: a client that cannot tell "the index is behind" from "your
  // request was malformed" cannot back off and retry, which is the only useful
  // response to this.
  it("refuses with the chain, its lag and a 503 once one is past the limit", async () => {
    heights = { [ETHEREUM]: chain(ETHEREUM, 101), [ARBITRUM]: chain(ARBITRUM, 0) };
    expect(await ask("everyChain")).toEqual({
      status: 200,
      body: {
        errors: [
          {
            message:
              "Chain 1 is 101 blocks behind head, past this resolver's limit of 100; refusing to answer from a stale index",
            extensions: { code: "SERVICE_UNAVAILABLE", http: { status: 503 } },
          },
        ],
      },
    });
  });

  it("refuses on the chain an object limit names", async () => {
    heights = { [ARBITRUM]: chain(ARBITRUM, 101) };
    expect(await ask("namedChains")).toEqual({
      status: 200,
      body: {
        errors: [
          {
            message:
              "Chain 42161 is 101 blocks behind head, past this resolver's limit of 100; refusing to answer from a stale index",
            extensions: { code: "SERVICE_UNAVAILABLE", http: { status: 503 } },
          },
        ],
      },
    });
  });

  // A resolver reading one chain's tables should not be refused for the lag of
  // a chain it never touches.
  it("ignores a chain an object limit does not name, however far behind it is", async () => {
    heights = { [ETHEREUM]: chain(ETHEREUM, 5_000_000), [ARBITRUM]: chain(ARBITRUM, 0) };
    expect(await ask("namedChains")).toEqual({
      status: 200,
      body: { data: "answered" },
    });
  });

  // Refusing everything because the probe itself failed would turn one broken
  // read into a total outage, so the gate opens rather than closes.
  it("answers when the freshness read itself fails", async () => {
    heightFailure = new Error("connection terminated");
    expect(await ask("everyChain")).toEqual({
      status: 200,
      body: { data: "answered" },
    });
  });

  it("never reads chain heights for a resolver that declares no limit", async () => {
    heights = { [ETHEREUM]: chain(ETHEREUM, 5_000_000) };
    const answer = await ask("ungated");
    expect({ answer, heightReads }).toEqual({
      answer: { status: 200, body: { data: "answered" } },
      heightReads: 0,
    });
  });

  // A burst arriving on a cold cache must not each take a connection to learn
  // the same answer: the probes alone can saturate the pool, and then the
  // check both costs every request its pool wait and stops working, under
  // exactly the load that makes staleness worth checking.
  it("reads chain heights once for a burst that arrives together", async () => {
    heights = { [ETHEREUM]: chain(ETHEREUM, 0) };
    heightDelayMs = 50;
    const answers = await Promise.all(Array.from({ length: 8 }, () => ask("everyChain")));
    expect({ answers, heightReads }).toEqual({
      answers: Array.from({ length: 8 }, () => ({ status: 200, body: { data: "answered" } })),
      heightReads: 1,
    });
  });
});
