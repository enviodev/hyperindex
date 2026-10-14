import { createServer, type IncomingMessage, type Server } from "node:http";
import { afterEach, describe, expect, it } from "vitest";
import { BigDecimal, S } from "envio";
import { Schema as UtilsSchema } from "envio/src/Utils.res.mjs";
import { createIndexerClient, IndexerClientError, testIndexerClient, toEntityMeta, type EntityMeta } from "envio/sidecar";

// Nullable entity columns use the same null-tolerant wrapper as the generated
// entity schemas, so a GraphQL `null` decodes to `undefined` like a DB row does.
const nullable = <T>(schema: S.Schema<T>): S.Schema<T | undefined> =>
  (UtilsSchema as { nullTolerant: (schema: S.Schema<T>) => S.Schema<T | undefined> }).nullTolerant(schema);

type Request = { readonly query: string; readonly variables: Record<string, unknown> };
type Responder = (request: Request, n: number) => unknown;

const readBody = (request: IncomingMessage): Promise<string> =>
  new Promise((resolve, reject) => {
    const chunks: Buffer[] = [];
    request.on("data", (chunk: Buffer) => chunks.push(chunk));
    request.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
    request.on("error", reject);
  });

const fakeGraphql = async (respond: Responder) => {
  const requests: Request[] = [];
  const headers: IncomingMessage["headers"][] = [];
  const server: Server = createServer((request, response) => {
    void readBody(request).then((raw) => {
      const parsed = JSON.parse(raw) as Request;
      requests.push(parsed);
      headers.push(request.headers);
      const answer = respond(parsed, requests.length);
      const status = typeof answer === "object" && answer !== null && "__status" in answer ? (answer as { __status: number }).__status : 200;
      response.writeHead(status, { "content-type": "application/json" });
      response.end(JSON.stringify(answer));
    });
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const address = server.address();
  if (address === null || typeof address === "string") throw new Error("no port");
  return {
    url: `http://127.0.0.1:${address.port}/v1/graphql`,
    requests,
    headers,
    close: () =>
      new Promise<void>((resolve) => {
        server.closeAllConnections();
        server.close(() => resolve());
      }),
  };
};

const cleanups: Array<() => Promise<void>> = [];
afterEach(async () => {
  for (const cleanup of cleanups.splice(0).reverse()) await cleanup();
});

const swapSchema = S.schema({ id: S.string, amount: S.bigint, usd: nullable(S.bigDecimal), seenAt: nullable(S.string) });
const swapMeta: EntityMeta = { name: "Swap", fields: ["id", "amount", "usd", "seenAt", "chainId"], chainIdField: "chainId", schema: swapSchema };
const tokenMeta: EntityMeta = { name: "Token", fields: ["id", "symbol"], schema: S.schema({ id: S.string, symbol: S.string }) };

type Swap = { id: string; amount: bigint; usd?: BigDecimal; seenAt?: string; chainId: number };
type Token = { id: string; symbol: string };
type Entities = { Swap: Swap; Token: Token };

const normalise = (query: string) => query.replace(/\s+/g, " ").trim();

describe("indexer read client over GraphQL", () => {
  it("get decodes the row through the entity schema and refuses an id present on two chains", async () => {
    const rowsByCall: unknown[][] = [[{ id: "a", amount: "10", usd: "1.5", seenAt: null, chainId: 1 }], [], [{ id: "c", chainId: 1 }, { id: "c", chainId: 10 }]];
    const graphql = await fakeGraphql((_request, n) => ({ data: { Swap: rowsByCall[n - 1] } }));
    cleanups.push(graphql.close);
    const client = createIndexerClient<Entities>({ url: graphql.url, entities: [swapMeta], role: "public" });
    const found = await client.Swap.get("a");
    const missing = await client.Swap.get("b");
    const twoChains = await client.Swap.get("c").then(
      () => "no error",
      (error: Error) => error.message,
    );
    expect({
      found: { ...found, usd: found?.usd?.toString() },
      missing,
      twoChains,
      firstRequest: { query: normalise(graphql.requests[0]?.query ?? ""), variables: graphql.requests[0]?.variables },
      role: graphql.headers[0]?.["x-hasura-role"],
    }).toEqual({
      found: { id: "a", amount: 10n, usd: "1.5", seenAt: undefined, chainId: 1 },
      missing: undefined,
      twoChains: "Entity `Swap` with id `c` exists on multiple chains, use getWhere({ chainId: { _eq: ... }, id: { _eq: ... } }) to pick one",
      firstRequest: {
        query:
          "query ($where: Swap_bool_exp, $order_by: [Swap_order_by!], $limit: Int, $offset: Int) { Swap(where: $where, order_by: $order_by, limit: $limit, offset: $offset) { id amount usd seenAt chainId } }",
        variables: { where: { id: { _eq: "a" } }, limit: 2 },
      },
      role: "public",
    });
  });

  it("getWhere encodes bigint and BigDecimal filters, caps the page at the response limit, orders", async () => {
    const graphql = await fakeGraphql(() => ({ data: { Swap: [] } }));
    cleanups.push(graphql.close);
    const client = createIndexerClient<Entities>({ url: graphql.url, entities: [swapMeta], responseLimit: 100 });
    await client.Swap.getWhere(
      { amount: { _gt: 5n, _in: [1n, 2n] }, usd: { _gte: new BigDecimal("2.25") }, chainId: { _eq: 1 } },
      { orderBy: { amount: "desc", id: "asc" }, limit: 5000, offset: 20 },
    );
    const all = await client.Swap.getAll();
    const getOrThrow = await client.Swap.getOrThrow("zzz").then(
      () => "no error",
      (error: Error) => error.message,
    );
    expect({ all, getOrThrow, variables: graphql.requests.map((r) => r.variables) }).toEqual({
      all: [],
      getOrThrow: "Entity `Swap` with id `zzz` not found",
      variables: [
        {
          where: { amount: { _gt: "5", _in: ["1", "2"] }, usd: { _gte: "2.25" }, chainId: { _eq: 1 } },
          order_by: [{ amount: "desc" }, { id: "asc" }],
          limit: 100,
          offset: 20,
        },
        { where: {}, limit: 100 },
        { where: { id: { _eq: "zzz" } }, limit: 2 },
      ],
    });
  });

  it("iterate walks a table with keyset pages on id (and chainId for per-chain entities)", async () => {
    const tokenPages = [[{ id: "a", symbol: "A" }, { id: "b", symbol: "B" }], [{ id: "c", symbol: "C" }]];
    const swapPages = [
      [
        { id: "x", amount: "1", usd: null, seenAt: null, chainId: 1 },
        { id: "x", amount: "2", usd: null, seenAt: null, chainId: 2 },
      ],
      [],
    ];
    let tokenCall = 0;
    let swapCall = 0;
    const graphql = await fakeGraphql((request) =>
      request.query.includes("Token(") ? { data: { Token: tokenPages[tokenCall++] } } : { data: { Swap: swapPages[swapCall++] } },
    );
    cleanups.push(graphql.close);
    const client = createIndexerClient<Entities>({ url: graphql.url, entities: [swapMeta, tokenMeta] });
    const tokens: string[] = [];
    for await (const token of client.Token.iterate({}, { pageSize: 2 })) tokens.push(token.id);
    const swaps: Array<[string, number]> = [];
    for await (const swap of client.Swap.iterate({ amount: { _gt: 0n } }, { pageSize: 2 })) swaps.push([swap.id, swap.chainId]);
    expect({ tokens, swaps, variables: graphql.requests.map((r) => r.variables) }).toEqual({
      tokens: ["a", "b", "c"],
      swaps: [
        ["x", 1],
        ["x", 2],
      ],
      variables: [
        { where: {}, order_by: [{ id: "asc" }], limit: 2 },
        { where: { _and: [{}, { id: { _gt: "b" } }] }, order_by: [{ id: "asc" }], limit: 2 },
        { where: { amount: { _gt: "0" } }, order_by: [{ id: "asc" }, { chainId: "asc" }], limit: 2 },
        {
          where: {
            _and: [
              { amount: { _gt: "0" } },
              { _or: [{ id: { _gt: "x" } }, { _and: [{ id: { _eq: "x" } }, { chainId: { _gt: 2 } }] }] },
            ],
          },
          order_by: [{ id: "asc" }, { chainId: "asc" }],
          limit: 2,
        },
      ],
    });
  });

  it("meta reads chain freshness and query is the raw escape hatch", async () => {
    const graphql = await fakeGraphql((request) =>
      request.query.includes("_meta")
        ? { data: { _meta: [{ chainId: 1, progressBlock: 10, sourceBlock: 12, readyAt: "2026-10-14T12:00:00Z", isReady: true }, { chainId: 2, progressBlock: 0, sourceBlock: 5, readyAt: null, isReady: false }] } }
        : { data: { Swap_aggregate: { aggregate: { count: 7 } } } },
    );
    cleanups.push(graphql.close);
    const client = createIndexerClient<Entities>({ url: graphql.url, entities: [swapMeta], secret: "testing" });
    const meta = await client.meta();
    const count = await client.query<{ Swap_aggregate: { aggregate: { count: number } } }>(
      "query ($min: numeric) { Swap_aggregate(where: { amount: { _gt: $min } }) { aggregate { count } } }",
      { min: 10n },
    );
    expect({ meta, count, lastVariables: graphql.requests[1]?.variables, secret: graphql.headers[0]?.["x-hasura-admin-secret"] }).toEqual({
      meta: [
        { chainId: 1, progressBlock: 10, sourceBlock: 12, readyAt: new Date("2026-10-14T12:00:00Z"), isReady: true },
        { chainId: 2, progressBlock: 0, sourceBlock: 5, readyAt: undefined, isReady: false },
      ],
      count: { Swap_aggregate: { aggregate: { count: 7 } } },
      lastVariables: { min: "10" },
      secret: "testing",
    });
  });

  it("surfaces GraphQL errors, HTTP failures and a missing endpoint as IndexerClientError", async () => {
    const graphql = await fakeGraphql((_request, n) => (n === 1 ? { errors: [{ message: "field 'nope' not found" }] } : { __status: 503, error: "down" }));
    cleanups.push(graphql.close);
    const client = createIndexerClient<Entities>({ url: graphql.url, entities: [swapMeta] });
    const describe = (error: unknown) =>
      error instanceof IndexerClientError ? { message: error.message, status: error.status, errors: error.graphqlErrors.length } : "wrong error";
    const graphqlError = await client.Swap.getAll().then(() => "no error", describe);
    const httpError = await client.Swap.getAll().then(() => "no error", describe);
    const unknownEntity = await (client as unknown as { Pool: { getAll: () => Promise<unknown> } }).Pool.getAll().then(() => "no error", describe);
    const noUrl = await createIndexerClient<Entities>({ url: undefined }).Swap.getAll().then(() => "no error", describe);
    expect({ graphqlError, httpError, unknownEntity, noUrl }).toEqual({
      graphqlError: { message: "GraphQL error: field 'nope' not found", status: 200, errors: 1 },
      httpError: { message: "GraphQL endpoint answered 503", status: 503, errors: 0 },
      unknownEntity: { message: "Unknown entity 'Pool'", status: undefined, errors: 0 },
      noUrl: { message: "ENVIO_GRAPHQL_URL is not set, the indexer client has no endpoint", status: undefined, errors: 0 },
    });
  });

  it("without entity definitions it learns scalar columns by introspection and returns raw values", async () => {
    const graphql = await fakeGraphql((request) =>
      request.query.includes("__type")
        ? {
            data: {
              __type: {
                fields: [
                  { name: "id", type: { kind: "NON_NULL", name: null, ofType: { kind: "SCALAR", name: "String", ofType: null } } },
                  { name: "amount", type: { kind: "NON_NULL", name: null, ofType: { kind: "SCALAR", name: "numeric", ofType: null } } },
                  { name: "pool", type: { kind: "OBJECT", name: "Pool", ofType: null } },
                  { name: "tags", type: { kind: "LIST", name: null, ofType: { kind: "NON_NULL", name: null, ofType: { kind: "SCALAR", name: "String", ofType: null } } } },
                ],
              },
            },
          }
        : { data: { Swap: [{ id: "a", amount: "10", tags: ["x"] }] } },
    );
    cleanups.push(graphql.close);
    const client = createIndexerClient<Entities>({ url: graphql.url });
    const rows = await client.Swap.getAll({ limit: 1 });
    await client.Swap.getAll({ limit: 1 });
    expect({ rows, queries: graphql.requests.map((r) => normalise(r.query).slice(0, 60)) }).toEqual({
      rows: [{ id: "a", amount: "10", tags: ["x"] }],
      queries: [
        "query ($name: String!) { __type(name: $name) { fields { name",
        "query ($where: Swap_bool_exp, $order_by: [Swap_order_by!], $",
        "query ($where: Swap_bool_exp, $order_by: [Swap_order_by!], $",
      ],
    });
  });

  it("accepts the runtime's own entity configs", () => {
    const meta = toEntityMeta({
      name: "Swap",
      schema: swapSchema,
      table: {
        fields: [
          { TAG: "Field", _0: { fieldName: "id", isChainId: false } },
          { TAG: "DerivedFrom", _0: { fieldName: "positions" } },
          { TAG: "Field", _0: { fieldName: "amount", isChainId: false } },
          { TAG: "Field", _0: { fieldName: "chainId", isChainId: true } },
        ],
      },
    });
    expect(meta).toEqual({ name: "Swap", fields: ["id", "amount", "chainId"], chainIdField: "chainId", schema: swapSchema });
  });
});

describe("testIndexerClient", () => {
  it("adds paging, ordering and iterate over the test indexer's entity operations", async () => {
    const rows: Token[] = [
      { id: "b", symbol: "BBB" },
      { id: "a", symbol: "AAA" },
      { id: "c", symbol: "CCC" },
    ];
    const fakeTestIndexer = {
      Token: {
        get: async (id: string) => rows.find((row) => row.id === id),
        getOrThrow: async (id: string) => {
          const row = rows.find((candidate) => candidate.id === id);
          if (row === undefined) throw new Error("missing");
          return row;
        },
        getAll: async () => [...rows],
        getWhere: async (filter: { id?: { _in?: string[] } }) => rows.filter((row) => filter.id?._in?.includes(row.id) ?? true),
        set: () => {},
      },
    };
    const client = testIndexerClient<Entities>(fakeTestIndexer);
    const page = await client.Token.getAll({ orderBy: { id: "asc" }, limit: 2, offset: 1 });
    const where = await client.Token.getWhere({ id: { _in: ["c", "a"] } }, { orderBy: { symbol: "desc" } });
    const iterated: string[] = [];
    for await (const token of client.Token.iterate({}, { orderBy: { id: "desc" } })) iterated.push(token.id);
    const one = await client.Token.get("a");
    const meta = await client.meta();
    expect({ page, where, iterated, one, meta }).toEqual({
      page: [
        { id: "b", symbol: "BBB" },
        { id: "c", symbol: "CCC" },
      ],
      where: [
        { id: "c", symbol: "CCC" },
        { id: "a", symbol: "AAA" },
      ],
      iterated: ["c", "b", "a"],
      one: { id: "a", symbol: "AAA" },
      meta: [],
    });
  });
});
