import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { S } from "envio";
import {
  createResolver,
  defineType,
  getRegisteredResolvers,
  ResolverError,
} from "envio/src/resolvers/index.js";
import {
  createResolverPool,
  createResolverPoolFromEnv,
  ResolverDbError,
} from "envio/src/resolvers/db.js";
import { startResolverServer } from "envio/src/resolvers/server.js";
import {
  createServer as createTcpServer,
  type Server as TcpServer,
  type Socket,
} from "node:net";

// The wire contract envio-serve already implements and tests. Everything here
// goes over real HTTP against a real server, because the shape of the bytes is
// the thing under test.

const Row = defineType("Row", { id: S.string, size: S.bigint });

let seen: Record<string, unknown> = {};

createResolver({
  name: "positions",
  args: { account: S.string, minSize: S.bigint },
  output: S.array(Row),
  timeoutMs: 5_000,
  handler: async ({ args, db, selection, ctx }) => {
    const rows = await db.sql.unsafe<{ n: number }>("SELECT 1::int AS n;");
    seen = { args, selection, role: ctx.role, requestId: ctx.requestId, n: rows[0]!.n };
    return [{ id: "p1", size: 250n }];
  },
});

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
});

createResolver({
  name: "boom",
  output: S.string,
  timeoutMs: 5_000,
  handler: async () => {
    throw new Error("connection to postgres://user:hunter2@db failed");
  },
});

createResolver({
  name: "wrongShape",
  output: S.array(Row),
  timeoutMs: 5_000,
  // @ts-expect-error -- deliberately returning something the output schema rejects
  handler: async () => [{ id: "p1" }],
});

// A resolver that may legitimately have no answer. `undefined` has no JSON
// form, so this is the shape that has to be handled rather than converted.
createResolver({
  name: "maybeRow",
  args: { found: S.boolean },
  output: S.optional(Row),
  timeoutMs: 5_000,
  handler: async ({ args }) => (args.found ? { id: "p1", size: 250n } : undefined),
});

// The two operational failures a caller should be able to tell apart from a
// bug: the pool being saturated, and a query hitting its statement_timeout.
createResolver({
  name: "saturated",
  output: S.string,
  timeoutMs: 5_000,
  handler: async () => {
    throw new ResolverDbError(
      "Timed out after 250ms waiting for one of the resolver pool's 8 connections.",
      "POOL_WAIT_TIMEOUT"
    );
  },
});

createResolver({
  name: "slowQuery",
  output: S.string,
  timeoutMs: 150,
  handler: async ({ db }) => {
    await db.sql.unsafe("SELECT pg_sleep(5);");
    return "never";
  },
});

createResolver({
  name: "adminOnly",
  output: S.string,
  admin: true,
  timeoutMs: 5_000,
  handler: async () => "secret",
});

let server: Awaited<ReturnType<typeof startResolverServer>>;
let pool: ReturnType<typeof createResolverPoolFromEnv>;

const resolve = async (body: unknown) => {
  const response = await fetch(`http://127.0.0.1:${server.port}/resolve`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });
  return { status: response.status, body: await response.json() };
};

beforeAll(async () => {
  pool = createResolverPoolFromEnv({ entities: {}, pgSchema: "public" });
  server = await startResolverServer({
    resolvers: getRegisteredResolvers(),
    pool,
    port: 0,
  });
});

afterAll(async () => {
  await server.close();
  await pool.end();
});

describe("resolver /resolve", () => {
  it("answers with the declared field names, args coerced and result serialized", async () => {
    const answer = await resolve({
      field: "positions",
      args: { account: "0xaaa", minSize: "100" },
      selection: { id: {}, size: {} },
      role: "public",
      requestId: "req-1",
    });
    expect({ answer, seen }).toEqual({
      answer: { status: 200, body: { data: [{ id: "p1", size: "250" }] } },
      // The handler sees a real bigint, not the string that came over the wire,
      // and the selection tree it can skip work on.
      seen: {
        args: { account: "0xaaa", minSize: 100n },
        selection: { id: {}, size: {} },
        role: "public",
        requestId: "req-1",
        n: 1,
      },
    });
  });

  it("carries a resolver's own error code and status through", async () => {
    expect(
      await resolve({
        field: "syncing",
        args: {},
        selection: {},
        role: "public",
        requestId: "req-2",
      })
    ).toEqual({
      status: 200,
      body: {
        errors: [
          {
            message: "Service is syncing",
            extensions: { code: "SERVICE_UNAVAILABLE", http: { status: 503 } },
          },
        ],
      },
    });
  });

  it("does not put an unexpected error's message on the wire", async () => {
    expect(
      await resolve({
        field: "boom",
        args: {},
        selection: {},
        role: "public",
        requestId: "req-3",
      })
    ).toEqual({
      status: 200,
      body: {
        errors: [
          {
            message: "Resolver 'boom' failed",
            extensions: { code: "INTERNAL_SERVER_ERROR" },
          },
        ],
      },
    });
  });

  it("fails the field when a result doesn't match its declared output", async () => {
    const answer = await resolve({
      field: "wrongShape",
      args: {},
      selection: { id: {} },
      role: "public",
      requestId: "req-4",
    });
    expect({
      status: answer.status,
      code: answer.body.errors[0].extensions.code,
      mentionsField: answer.body.errors[0].message.includes("wrongShape"),
    }).toEqual({ status: 200, code: "INVALID_RESULT", mentionsField: true });
  });

  it("refuses an admin resolver asked for as public", async () => {
    expect(
      await resolve({
        field: "adminOnly",
        args: {},
        selection: {},
        role: "public",
        requestId: "req-5",
      })
    ).toEqual({
      status: 200,
      body: {
        errors: [
          {
            message: "Resolver 'adminOnly' is admin-only",
            extensions: { code: "FORBIDDEN" },
          },
        ],
      },
    });
  });

  it("answers an admin resolver asked for as admin", async () => {
    expect(
      await resolve({
        field: "adminOnly",
        args: {},
        selection: {},
        role: "admin",
        requestId: "req-6",
      })
    ).toEqual({ status: 200, body: { data: "secret" } });
  });

  it("refuses a field it has no resolver for", async () => {
    expect(
      await resolve({
        field: "notDeclared",
        args: {},
        selection: {},
        role: "public",
        requestId: "req-7",
      })
    ).toEqual({
      status: 200,
      body: {
        errors: [
          {
            message: "No resolver named 'notDeclared' is registered",
            extensions: { code: "RESOLVER_NOT_FOUND" },
          },
        ],
      },
    });
  });

  it("answers null for a nullable result, and the value when there is one", async () => {
    const [absent, present] = await Promise.all([
      resolve({
        field: "maybeRow",
        args: { found: false },
        selection: { id: {} },
        role: "public",
        requestId: "req-n1",
      }),
      resolve({
        field: "maybeRow",
        args: { found: true },
        selection: { id: {}, size: {} },
        role: "public",
        requestId: "req-n2",
      }),
    ]);
    expect([absent, present]).toEqual([
      { status: 200, body: { data: null } },
      { status: 200, body: { data: { id: "p1", size: "250" } } },
    ]);
  });

  it("tells an operational failure apart from a bug", async () => {
    // §7.4 wants pool exhaustion to surface as a clean per-field error. Both
    // of these are the resolver's own capacity, not a leaked internal, so
    // their codes reach the client where a driver error's message would not.
    const [saturated, slow] = await Promise.all([
      resolve({
        field: "saturated",
        args: {},
        selection: {},
        role: "public",
        requestId: "req-s1",
      }),
      resolve({
        field: "slowQuery",
        args: {},
        selection: {},
        role: "public",
        requestId: "req-s2",
      }),
    ]);
    expect([
      saturated.body.errors[0].extensions,
      slow.body.errors[0].extensions,
    ]).toEqual([
      { code: "POOL_WAIT_TIMEOUT", http: { status: 503 } },
      { code: "STATEMENT_TIMEOUT", http: { status: 503 } },
    ]);
  });

  it("rejects a body that isn't a resolve request", async () => {
    const answer = await resolve({ field: 42 });
    expect({
      status: answer.status,
      code: answer.body.errors[0].extensions.code,
    }).toEqual({ status: 400, code: "BAD_REQUEST" });
  });

  it("reports liveness, and readiness once the database answers", async () => {
    const [healthz, readyz] = await Promise.all([
      fetch(`http://127.0.0.1:${server.port}/healthz`),
      fetch(`http://127.0.0.1:${server.port}/readyz`),
    ]);
    expect([healthz.status, readyz.status]).toEqual([200, 200]);
  });

  it("is live but not ready when the database is unreachable", async () => {
    // Ready has to mean the database answers. A process that is up and cannot
    // reach Postgres has nothing to serve, and taking traffic is worse than
    // being restarted.
    const brokenPool = createResolverPool({
      // Nothing listens on port 1, so the probe has to say so.
      connection: {
        host: "127.0.0.1",
        port: 1,
        username: "postgres",
        password: "testing",
        database: "envio-dev",
      },
      entities: {},
      pgSchema: "public",
      poolSize: 1,
    });
    const broken = await startResolverServer({
      resolvers: [],
      pool: brokenPool,
      port: 0,
    });
    try {
      const [healthz, readyz] = await Promise.all([
        fetch(`http://127.0.0.1:${broken.port}/healthz`),
        fetch(`http://127.0.0.1:${broken.port}/readyz`),
      ]);
      expect([healthz.status, readyz.status]).toEqual([200, 503]);
    } finally {
      await broken.close();
      await brokenPool.end().catch(() => {});
    }
  });

  // A refused connection is the easy case. A Postgres that accepts the socket
  // and never finishes the handshake is the one that hurts: `statement_timeout`
  // has not been sent yet, so only the pool's `connect_timeout` bounds it, and
  // that is sized for the pool wait rather than for a probe. A readiness check
  // that outlives its own budget is one the orchestrator times out on instead,
  // which reports the pod as unready without ever saying why.
  it("answers readiness within its budget when the database stalls the handshake", async () => {
    const accepted: Socket[] = [];
    const blackHole: TcpServer = createTcpServer((socket) => {
      // Accepted, then silence. The Postgres startup packet is never answered.
      socket.on("error", () => {});
      accepted.push(socket);
    });
    await new Promise<void>((resolve) => blackHole.listen(0, "127.0.0.1", () => resolve()));
    const address = blackHole.address();
    const stalledPool = createResolverPool({
      connection: {
        host: "127.0.0.1",
        port: typeof address === "object" && address ? address.port : 0,
        username: "postgres",
        password: "testing",
        database: "envio-dev",
      },
      entities: {},
      pgSchema: "public",
      poolSize: 1,
      // The pool's own bound on a connect, well past the probe's budget: what
      // is under test is that the probe does not wait for it.
      poolWaitTimeoutMs: 20_000,
    });
    const stalled = await startResolverServer({ resolvers: [], pool: stalledPool, port: 0 });
    try {
      const started = Date.now();
      const readyz = await fetch(`http://127.0.0.1:${stalled.port}/readyz`);
      const body = await readyz.json();
      const elapsed = Date.now() - started;
      expect([readyz.status, body, elapsed < 4_000]).toEqual([
        503,
        { status: "unavailable", reason: "The database did not answer within 2000ms." },
        true,
      ]);
    } finally {
      await stalled.close();
      // Not awaited, and the sockets are cut rather than drained: the connect
      // this pool is still attempting has 20 seconds to run, and the driver
      // opens a fresh one each time this end of it goes away.
      stalledPool.end().catch(() => {});
      for (const socket of accepted) socket.destroy();
      await new Promise<void>((resolve) => blackHole.close(() => resolve()));
    }
  });

  // Saturation and silence are different failures and need different answers.
  // The probe's own wall clock is the bound on a database that never speaks;
  // it must not also be the first thing to fire when the pool is merely busy,
  // because then a pod under load reports a database fault it does not have.
  it("blames the pool, not the database, when the pool is the thing that is full", async () => {
    const busyPool = createResolverPoolFromEnv({ entities: {}, pgSchema: "public", poolSize: 1 });
    const busy = await startResolverServer({ resolvers: [], pool: busyPool, port: 0 });
    // Hold the pool's only connection for longer than the probe will wait.
    const hog = busyPool
      .forResolver({ name: "hog", timeoutMs: 10_000 })
      .sql.unsafe("SELECT pg_sleep(3);")
      .catch(() => {});
    try {
      const readyz = await fetch(`http://127.0.0.1:${busy.port}/readyz`);
      const body = (await readyz.json()) as { status: string; reason: string };
      expect([readyz.status, /pool/i.test(body.reason)]).toEqual([503, true]);
    } finally {
      await hog;
      await busy.close();
      await busyPool.end().catch(() => {});
    }
  });

  it("puts an unexpected error's message on the wire only in dev", async () => {
    const dev = await startResolverServer({
      resolvers: getRegisteredResolvers(),
      pool,
      port: 0,
      exposeErrors: true,
      onError: () => {},
    });
    try {
      const response = await fetch(`http://127.0.0.1:${dev.port}/resolve`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          field: "boom",
          args: {},
          selection: {},
          role: "public",
          requestId: "req-dev",
        }),
      });
      const body = await response.json();
      expect(body.errors[0].message).toEqual(
        "Resolver 'boom' failed: connection to postgres://user:hunter2@db failed"
      );
    } finally {
      await dev.close();
    }
  });
});
