import { afterAll, beforeAll, describe, expect, it } from "vitest";
import {
  createResolver,
  defineInput,
  defineType,
  ResolverError,
  S,
} from "envio";
import { createResolverPoolFromEnv } from "../../envio/src/resolvers/db.js";
import { startResolverServer } from "../../envio/src/resolvers/server.js";

// Hasura's action contract, over real HTTP. It is not envio-serve's: the result
// is returned bare rather than under `data`, and a failure is a status code
// rather than an `errors` array, which is the only way Hasura can tell the two
// apart.

const Row = defineType("Row", { id: S.string, size: S.bigint });

const MarketAprsWhereInput = defineInput("MarketAprsWhereInput", {
  periodStart: S.int32,
  marketAddresses: S.optional(S.array(S.string)),
});
const CodeTierRuleInput = defineInput("CodeTierRuleInput", {
  tier: S.string,
  share: S.string,
});

let seen: Record<string, unknown> = {};

const resolvers = [
  createResolver({
    name: "positions",
    args: { account: S.string, minSize: S.bigint },
    output: S.array(Row),
    timeoutMs: 5_000,
    handler: async ({ args, db, selection, ctx }) => {
      const rows = await db.sql.unsafe<{ n: number }>("SELECT 1::int AS n;");
      seen = {
        args,
        selection,
        role: ctx.role,
        requestIdIsString: typeof ctx.requestId === "string" && ctx.requestId.length > 0,
        n: rows[0]!.n,
      };
      return [{ id: "p1", size: 250n }];
    },
  }),

  createResolver({
    name: "maybeRow",
    args: { found: S.boolean },
    output: S.optional(Row),
    timeoutMs: 5_000,
    handler: async ({ args }) => (args.found ? { id: "p1", size: 250n } : undefined),
  }),

  createResolver({
    name: "syncing",
    output: S.string,
    timeoutMs: 5_000,
    handler: async () => {
      throw new ResolverError("Service is syncing", {
        code: "SERVICE_UNAVAILABLE",
        httpStatus: 503,
      });
    },
  }),

  createResolver({
    name: "boom",
    output: S.string,
    timeoutMs: 5_000,
    handler: async () => {
      throw new Error("connection to postgres://user:hunter2@db failed");
    },
  }),

  createResolver({
    name: "marketsAprByPeriod",
    args: {
      where: MarketAprsWhereInput,
      codeTiersAsc: S.optional(S.array(CodeTierRuleInput)),
    },
    output: S.string,
    timeoutMs: 5_000,
    handler: async ({ args }) => JSON.stringify(args),
  }),

  createResolver({
    name: "selectionProbe",
    output: S.string,
    timeoutMs: 5_000,
    handler: async ({ selection }) => JSON.stringify(selection),
  }),

  createResolver({
    name: "adminOnly",
    output: S.string,
    admin: true,
    timeoutMs: 5_000,
    handler: async () => "secret",
  }),
];

let server: Awaited<ReturnType<typeof startResolverServer>>;
let pool: ReturnType<typeof createResolverPoolFromEnv>;

const action = async (body: unknown) => {
  const response = await fetch(`http://127.0.0.1:${server.port}/hasura-action`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });
  return { status: response.status, body: await response.json() };
};

beforeAll(async () => {
  pool = createResolverPoolFromEnv({ entities: {}, pgSchema: "public" });
  server = await startResolverServer({
    resolvers,
    pool,
    port: 0,
    onError: () => {},
  });
});

afterAll(async () => {
  await server.close();
  await pool.end();
});

describe("resolver /hasura-action", () => {
  it("answers with the bare result, arguments coerced from `input`", async () => {
    const answer = await action({
      action: { name: "positions" },
      input: { account: "0xaaa", minSize: "100" },
      session_variables: { "x-hasura-role": "public" },
      request_query: "query { positions(account: \"0xaaa\", minSize: \"100\") { id size } }",
    });
    expect({ answer, seen }).toEqual({
      // Not `{ data: … }`: Hasura splices the body in as the field's value.
      answer: { status: 200, body: [{ id: "p1", size: "250" }] },
      seen: {
        args: { account: "0xaaa", minSize: 100n },
        selection: { id: {}, size: {} },
        role: "public",
        // Hasura sends no request id, so the service mints one -- without it a
        // failure in the logs cannot be tied to the request that caused it.
        requestIdIsString: true,
        n: 1,
      },
    });
  });

  it("answers null for a nullable result with nothing to return", async () => {
    expect(
      await action({
        action: { name: "maybeRow" },
        input: { found: false },
        session_variables: { "x-hasura-role": "public" },
        request_query: "query { maybeRow(found: false) { id } }",
      })
    ).toEqual({ status: 200, body: null });
  });

  it("reports an unknown action as a failure status, not a 200", async () => {
    expect(
      await action({
        action: { name: "notDeclared" },
        input: {},
        session_variables: { "x-hasura-role": "public" },
        request_query: "query { notDeclared }",
      })
    ).toEqual({
      status: 404,
      body: {
        message: "No resolver named 'notDeclared' is registered",
        extensions: { code: "RESOLVER_NOT_FOUND" },
      },
    });
  });

  it("refuses an admin resolver for a non-admin role, and answers it for admin", async () => {
    // Enforced here as well as by Hasura's action permissions: the handler is
    // reachable from inside the cluster without going through Hasura at all.
    const [refused, answered] = await Promise.all([
      action({
        action: { name: "adminOnly" },
        input: {},
        session_variables: { "x-hasura-role": "public" },
        request_query: "query { adminOnly }",
      }),
      action({
        action: { name: "adminOnly" },
        input: {},
        session_variables: { "x-hasura-role": "admin" },
        request_query: "query { adminOnly }",
      }),
    ]);
    expect([refused, answered]).toEqual([
      {
        status: 403,
        body: {
          message: "Resolver 'adminOnly' is admin-only",
          extensions: { code: "FORBIDDEN" },
        },
      },
      { status: 200, body: "secret" },
    ]);
  });

  it("treats a missing or unrecognised role as public", async () => {
    // Hasura roles are arbitrary strings; anything that is not `admin` gets the
    // public treatment rather than being rejected outright.
    const [absent, unknown] = await Promise.all([
      action({
        action: { name: "adminOnly" },
        input: {},
        request_query: "query { adminOnly }",
      }),
      action({
        action: { name: "adminOnly" },
        input: {},
        session_variables: { "x-hasura-role": "editor" },
        request_query: "query { adminOnly }",
      }),
    ]);
    expect([absent.status, unknown.status]).toEqual([403, 403]);
  });

  it("carries a resolver's own code through, at a status Hasura reads as an error", async () => {
    const answer = await action({
      action: { name: "syncing" },
      input: {},
      session_variables: { "x-hasura-role": "public" },
      request_query: "query { syncing }",
    });
    // Hasura only documents 4xx as a handler error, so the resolver's intended
    // 503 travels in `extensions` rather than in the status line.
    expect(answer).toEqual({
      status: 400,
      body: {
        message: "Service is syncing",
        extensions: { code: "SERVICE_UNAVAILABLE", http: { status: 503 } },
      },
    });
  });

  it("does not put an unexpected error's message on the wire", async () => {
    expect(
      await action({
        action: { name: "boom" },
        input: {},
        session_variables: { "x-hasura-role": "public" },
        request_query: "query { boom }",
      })
    ).toEqual({
      status: 400,
      body: {
        message: "Resolver 'boom' failed",
        extensions: { code: "INTERNAL_SERVER_ERROR" },
      },
    });
  });

  it("rejects a body that is not an action payload", async () => {
    const answer = await action({ input: {} });
    expect({
      status: answer.status,
      code: answer.body.extensions.code,
    }).toEqual({ status: 400, code: "BAD_REQUEST" });
  });

  it("gives the handler the selection Hasura's callers asked for", async () => {
    // Hasura sends the operation as text, not as a parsed selection, so the
    // tree a resolver skips work on has to be recovered from it. GMX's PnL
    // resolver skips a TradeAction aggregation when the fee breakdown is not
    // requested, which is the whole reason this is not left empty.
    const queries: [string, string][] = [
      ["plain", `query { selectionProbe { openFeesUsd closeFeesUsd } }`],
      // The declared field name, never the alias -- a resolver knows its own
      // result type and nothing about what the caller renamed it to.
      ["aliases", `query { probe: selectionProbe { fees: openFeesUsd } }`],
      ["nested", `query { selectionProbe { bucket { openFeesUsd } } }`],
      [
        "fragments",
        `query { selectionProbe { ...Fees ... on Bucket { closeFeesUsd } } }
         fragment Fees on Bucket { openFeesUsd }`,
      ],
      // A brace or a hash inside a string argument is not structure.
      ["string args", `query { selectionProbe(note: "} # { not a selection") { openFeesUsd } }`],
      [
        "block strings",
        `query { selectionProbe(note: """
           } still not a selection
         """) { openFeesUsd } }`,
      ],
      [
        "comments and commas",
        `query {  # the fee breakdown
           selectionProbe { openFeesUsd, closeFeesUsd }  # both of them
         }`,
      ],
      [
        "variables and directives",
        `query Fees($withClose: Boolean! = true) @cached {
           selectionProbe(note: $note) { openFeesUsd closeFeesUsd @include(if: $withClose) }
         }`,
      ],
      // Hasura merges actions into the query root beside table fields, so the
      // document routinely holds selections that are not ours.
      [
        "other root fields",
        `query { Account(where: { id: { _eq: "0x" } }) { id } selectionProbe { openFeesUsd } }`,
      ],
      ["__typename", `query { selectionProbe { __typename openFeesUsd } }`],
      // The same action asked for twice in one document, and a fragment cycle
      // that would otherwise be followed forever.
      [
        "repeated field",
        `query { selectionProbe { openFeesUsd } selectionProbe { closeFeesUsd } }`,
      ],
      [
        "fragment cycle",
        `query { selectionProbe { ...A } }
         fragment A on Bucket { openFeesUsd ...B }
         fragment B on Bucket { closeFeesUsd ...A }`,
      ],
      // The selection is an optimisation, never correctness: anything that
      // cannot be read leaves the resolver doing its full work.
      ["unparseable", `query { selectionProbe { openFeesUsd `],
      ["absent", ``],
    ];

    const seenSelections = await Promise.all(
      queries.map(async ([label, request_query]) => {
        const answer = await action({
          action: { name: "selectionProbe" },
          input: {},
          session_variables: { "x-hasura-role": "public" },
          ...(request_query === "" ? {} : { request_query }),
        });
        return [label, JSON.parse(answer.body as string)];
      })
    );

    expect(seenSelections).toEqual([
      ["plain", { openFeesUsd: {}, closeFeesUsd: {} }],
      ["aliases", { openFeesUsd: {} }],
      ["nested", { bucket: { openFeesUsd: {} } }],
      ["fragments", { openFeesUsd: {}, closeFeesUsd: {} }],
      ["string args", { openFeesUsd: {} }],
      ["block strings", { openFeesUsd: {} }],
      ["comments and commas", { openFeesUsd: {}, closeFeesUsd: {} }],
      ["variables and directives", { openFeesUsd: {}, closeFeesUsd: {} }],
      ["other root fields", { openFeesUsd: {} }],
      ["__typename", { openFeesUsd: {} }],
      ["repeated field", { openFeesUsd: {}, closeFeesUsd: {} }],
      ["fragment cycle", { openFeesUsd: {}, closeFeesUsd: {} }],
      ["unparseable", {}],
      ["absent", {}],
    ]);
  });

  it("coerces an object-shaped argument through its declared input type", async () => {
    // Nearly every resolver in the reference implementation takes a `where`
    // argument, so Hasura's nested `input` has to reach the handler as the
    // object the declaration describes -- optional members absent rather than
    // null, and a list of input objects intact.
    expect(
      await action({
        action: { name: "marketsAprByPeriod" },
        input: {
          where: { periodStart: 1735689600, marketAddresses: ["0xaaa", "0xbbb"] },
          codeTiersAsc: [{ tier: "1", share: "500" }],
        },
        session_variables: { "x-hasura-role": "public" },
        request_query: "query { marketsAprByPeriod(where: { periodStart: 1735689600 }) }",
      })
    ).toEqual({
      status: 200,
      body: JSON.stringify({
        where: { periodStart: 1735689600, marketAddresses: ["0xaaa", "0xbbb"] },
        codeTiersAsc: [{ tier: "1", share: "500" }],
      }),
    });
  });

  it("rejects an argument the declared input type refuses", async () => {
    const answer = await action({
      action: { name: "marketsAprByPeriod" },
      input: { where: { periodStart: "not a number" } },
      session_variables: { "x-hasura-role": "public" },
      request_query: "query { marketsAprByPeriod(where: {}) }",
    });
    expect({
      status: answer.status,
      code: (answer.body as { extensions: { code: string } }).extensions.code,
    }).toEqual({ status: 400, code: "BAD_USER_INPUT" });
  });

  it("leaves /resolve answering serve's contract", async () => {
    // serve is dormant, not dead: the two routes share a dispatcher and the
    // envio-serve wire shape must not move underneath it.
    const response = await fetch(`http://127.0.0.1:${server.port}/resolve`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        field: "maybeRow",
        args: { found: true },
        selection: { id: {}, size: {} },
        role: "public",
        requestId: "req-serve",
      }),
    });
    expect({ status: response.status, body: await response.json() }).toEqual({
      status: 200,
      body: { data: { id: "p1", size: "250" } },
    });
  });
});
