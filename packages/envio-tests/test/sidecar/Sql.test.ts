import postgres from "postgres";
import { afterAll, afterEach, beforeAll, describe, expect, it } from "vitest";
import {
  createSidecarSql,
  readEnv,
  SidecarSqlDisabledError,
  SidecarSqlError,
  type SidecarSqlEnv,
  type SidecarSqlHandle,
} from "envio/sidecar";

// The database the suite's global setup already requires (envio dev's, or the
// one CI starts), read the way the indexer's Env.res reads it.
const db = {
  host: process.env.ENVIO_PG_HOST ?? "localhost",
  port: Number(process.env.ENVIO_PG_PORT ?? 5433),
  database: process.env.ENVIO_PG_DATABASE ?? "envio-dev",
  user: process.env.ENVIO_PG_USER ?? "postgres",
  password: process.env.ENVIO_PG_PASSWORD ?? "testing",
};

// The capital letter makes every unquoted use of the schema fail.
const schema = `envio_test_${Date.now()}_${process.pid}_Sql`;
const role = "envio_sidecar_test";

const admin = postgres({ ...db, username: db.user, max: 1, onnotice: () => {} });

const config = (overrides: Partial<SidecarSqlEnv> = {}): SidecarSqlEnv => ({
  host: db.host,
  port: db.port,
  database: db.database,
  user: role,
  password: "testing",
  schema,
  ssl: false,
  poolerBacked: false,
  timeoutMs: 5_000,
  poolSize: 5,
  poolWaitMs: 10_000,
  ...overrides,
});

const handles: SidecarSqlHandle[] = [];
const open = (overrides: Partial<SidecarSqlEnv> = {}, options: Parameters<typeof createSidecarSql>[1] = {}) => {
  const sql = createSidecarSql(config(overrides), options);
  handles.push(sql);
  return sql;
};

afterEach(async () => {
  for (const sql of handles.splice(0)) await sql.end(1_000);
});

const caught = async (promise: Promise<unknown>) => {
  try {
    await promise;
  } catch (error) {
    return error;
  }
  throw new Error("expected a rejection");
};

const swapCount = async () => {
  const [row] = await admin.unsafe(`select count(*)::int as n from "${schema}"."Swap"`);
  return (row as { n: number }).n;
};

beforeAll(async () => {
  await admin.unsafe(`
    DO $$ BEGIN
      CREATE ROLE ${role} LOGIN PASSWORD 'testing' IN ROLE pg_read_all_data;
    EXCEPTION WHEN duplicate_object THEN NULL; END $$;`);
  await admin.unsafe(`CREATE SCHEMA "${schema}"`);
  await admin.unsafe(`CREATE TABLE "${schema}"."Swap" (id text primary key, trader text not null, amount_usd numeric not null)`);
  await admin.unsafe(`INSERT INTO "${schema}"."Swap" VALUES ('s1', 'alice', 100), ('s2', 'alice', 250), ('s3', 'bob', 300)`);
});

afterAll(async () => {
  await admin.unsafe(`DROP SCHEMA IF EXISTS "${schema}" CASCADE`);
  await admin.end();
});

describe("sidecar sql: reads", () => {
  it("selects through table() from a non-public schema and a mixed-case table, values as parameters", async () => {
    const sql = open();
    const rows = await sql<{ trader: string; volume: string }[]>`
      select trader, sum(amount_usd)::text as volume from ${sql.table("Swap")}
      where amount_usd >= ${100} group by trader order by trader`;
    expect({ rows: [...rows], schema: sql.schema, enabled: sql.enabled }).toEqual({
      rows: [
        { trader: "alice", volume: "350" },
        { trader: "bob", volume: "300" },
      ],
      schema,
      enabled: true,
    });
  });

  it("quotes a table name, so a crafted one stays one identifier", async () => {
    const sql = open();
    const error = await caught(sql`select * from ${sql.table('Swap"; drop table "Swap')}`);
    expect({ error, count: await swapCount() }).toEqual({
      error: expect.objectContaining({ name: "SidecarSqlError", code: "QUERY_FAILED", sqlState: "42P01" }),
      count: 3,
    });
  });

  it("runs unsafe with a params array, refuses it without one, and refuses a call that is not a template", async () => {
    const sql = open();
    const rows = await sql.unsafe<{ id: string }[]>(`select id from "${schema}"."Swap" where trader = $1 order by id`, [
      "bob",
    ]);
    const missing = await caught((sql.unsafe as (text: string) => Promise<unknown>)("select 1"));
    const notTemplate = await caught((sql as unknown as (text: string) => Promise<unknown>)("select 1"));
    expect({ rows: [...rows], missing, notTemplate }).toEqual({
      rows: [{ id: "s3" }],
      missing: expect.objectContaining({ name: "SidecarSqlError", code: "INVALID_ARGUMENT" }),
      notTemplate: expect.objectContaining({ name: "SidecarSqlError", code: "INVALID_ARGUMENT" }),
    });
  });

  it("warns once per query text when a result is over 10000 rows", async () => {
    const warnings: string[] = [];
    const log = { debug: () => {}, info: () => {}, error: () => {}, warn: (message: string) => warnings.push(message) };
    const sql = open({}, { log });
    for (let i = 0; i < 2; i++) await sql`select g from generate_series(1, ${10_001}) g`;
    await sql`select g from generate_series(1, ${10}) g`;
    expect(warnings).toEqual(["sql query returned 10001 rows, over 10000: page it or aggregate in SQL"]);
  });
});

describe("sidecar sql: read only", () => {
  it("refuses INSERT and CREATE TABLE even when connected as the superuser", async () => {
    const sql = open({ user: db.user, password: db.password });
    const insert = await caught(sql`insert into ${sql.table("Swap")} values ('s4', 'eve', 1)`);
    const create = await caught(sql`create table ${sql.table("Evil")} (id int)`);
    expect({ insert, create, count: await swapCount() }).toEqual({
      insert: expect.objectContaining({ name: "SidecarSqlError", code: "READ_ONLY", sqlState: "25006" }),
      create: expect.objectContaining({ name: "SidecarSqlError", code: "READ_ONLY", sqlState: "25006" }),
      count: 3,
    });
  });

  it("cannot COMMIT out of the read only transaction with a multi statement unsafe", async () => {
    const sql = open({ user: db.user, password: db.password });
    const error = await caught(
      sql.unsafe(`select 1; commit; insert into "${schema}"."Swap" values ('s5', 'eve', 1)`, []),
    );
    expect({ error, count: await swapCount() }).toEqual({
      error: expect.objectContaining({ name: "SidecarSqlError", code: "QUERY_FAILED", sqlState: "42601" }),
      count: 3,
    });
  });
});

describe("sidecar sql: limits", () => {
  it("cancels a statement at the timeout", async () => {
    const sql = open({ timeoutMs: 200 });
    const startedAt = Date.now();
    const error = await caught(sql`select pg_sleep(5)`);
    expect({ error, fast: Date.now() - startedAt < 3_000 }).toEqual({
      error: expect.objectContaining({ name: "SidecarSqlError", code: "STATEMENT_TIMEOUT", sqlState: "57014" }),
      fast: true,
    });
  });

  it("fails fast once the pool is saturated instead of queueing forever", async () => {
    const sql = open({ poolSize: 1, poolWaitMs: 50 });
    const held = sql`select pg_sleep(0.5)`;
    const queued = await caught(sql`select 1`);
    const during = sql.stats();
    await held;
    expect({ queued, during, after: sql.stats() }).toEqual({
      queued: expect.objectContaining({ name: "SidecarSqlError", code: "POOL_WAIT_TIMEOUT" }),
      during: { poolSize: 1, inUse: 1, waiting: 0 },
      after: { poolSize: 1, inUse: 0, waiting: 0 },
    });
  });
});

describe("sidecar sql: transaction", () => {
  it("runs several queries on one connection, REPEATABLE READ and READ ONLY, under its own timeout", async () => {
    const sql = open();
    const seen = await sql.transaction(
      async (tx) => {
        const [first] = await tx<{ pid: number }[]>`select pg_backend_pid() as pid`;
        const [second] = await tx.unsafe<{ pid: number }[]>("select pg_backend_pid() as pid", []);
        const [settings] = await tx`
          select current_setting('transaction_isolation') as isolation,
                 current_setting('transaction_read_only') as "readOnly",
                 current_setting('statement_timeout') as timeout`;
        const [total] = await tx`select count(*)::int as n from ${tx.table("Swap")}`;
        return { samePid: first?.pid === second?.pid, settings, total, schema: tx.schema };
      },
      { timeoutMs: 1_500 },
    );
    expect(seen).toEqual({
      samePid: true,
      settings: { isolation: "repeatable read", readOnly: "on", timeout: "1500ms" },
      total: { n: 3 },
      schema,
    });
  });

  it("passes a user's own error through, maps a query error, and clamps timeoutMs to 60 s", async () => {
    const sql = open();
    const own = await caught(
      sql.transaction(async () => {
        throw new Error("mine");
      }),
    );
    const write = await caught(sql.transaction(async (tx) => tx`delete from ${tx.table("Swap")}`));
    const clamped = await sql.transaction(async (tx) => tx`select current_setting('statement_timeout') as t`, {
      timeoutMs: 120_000,
    });
    const invalid = await caught(sql.transaction(async () => 1, { timeoutMs: 0 }));
    expect({ own, write, clamped: [...clamped], invalid, count: await swapCount() }).toEqual({
      own: new Error("mine"),
      write: expect.objectContaining({ name: "SidecarSqlError", code: "READ_ONLY" }),
      clamped: [{ t: "1min" }],
      invalid: expect.objectContaining({ name: "SidecarSqlError", code: "INVALID_ARGUMENT" }),
      count: 3,
    });
  });
});

describe("sidecar sql: disabled and env", () => {
  it("rejects every call on the disabled handle with SidecarSqlDisabledError", async () => {
    const sql = createSidecarSql(undefined);
    let tableError: unknown;
    try {
      sql.table("Swap");
    } catch (error) {
      tableError = error;
    }
    const errors = [
      await caught(sql`select 1`),
      await caught(sql.unsafe("select 1", [])),
      await caught(sql.transaction(async () => 1)),
      tableError,
    ];
    expect({
      enabled: sql.enabled,
      allDisabled: errors.every((error) => error instanceof SidecarSqlDisabledError),
      message: (errors[0] as Error).message,
      isSqlError: errors[0] instanceof SidecarSqlError,
    }).toEqual({
      enabled: false,
      allDisabled: true,
      message:
        "sql is not available: it needs ENVIO_SIDECAR_PG_HOST, _USER and _DATABASE, which are set only on dedicated deployments with ENVIO_SIDECAR_SQL=true, or locally under envio dev",
      isSqlError: false,
    });
  });

  it("reads ENVIO_SIDECAR_PG_* only when host, user and database are set, with defaults and clamps", () => {
    const base = { ENVIO_SIDECAR_PG_HOST: "pg-x-rw", ENVIO_SIDECAR_PG_USER: "envio_sidecar", ENVIO_SIDECAR_PG_DATABASE: "d" };
    expect({
      none: readEnv({}).sql,
      noUser: readEnv({ ...base, ENVIO_SIDECAR_PG_USER: "" }).sql,
      defaults: readEnv(base).sql,
      set: readEnv({
        ...base,
        ENVIO_SIDECAR_PG_PORT: "6432",
        ENVIO_SIDECAR_PG_PASSWORD: "pw",
        ENVIO_SIDECAR_PG_SCHEMA: "Indexer",
        ENVIO_SIDECAR_PG_SSL_MODE: "require",
        ENVIO_SIDECAR_PG_POOLER_BACKED: "true",
        ENVIO_SIDECAR_SQL_TIMEOUT_MS: "120000",
        ENVIO_SIDECAR_SQL_POOL_SIZE: "2",
      }).sql,
      sslOff: ["", "disable", "false"].map((mode) => readEnv({ ...base, ENVIO_SIDECAR_PG_SSL_MODE: mode }).sql?.ssl),
      sslOn: ["true", "allow", "prefer", "verify-full"].map(
        (mode) => readEnv({ ...base, ENVIO_SIDECAR_PG_SSL_MODE: mode }).sql?.ssl,
      ),
    }).toEqual({
      none: undefined,
      noUser: undefined,
      defaults: {
        host: "pg-x-rw",
        port: 5432,
        database: "d",
        user: "envio_sidecar",
        password: undefined,
        schema: "public",
        ssl: false,
        poolerBacked: false,
        timeoutMs: 10_000,
        poolSize: 5,
        poolWaitMs: 10_000,
      },
      set: {
        host: "pg-x-rw",
        port: 6432,
        database: "d",
        user: "envio_sidecar",
        password: "pw",
        schema: "Indexer",
        ssl: "require",
        poolerBacked: true,
        timeoutMs: 60_000,
        poolSize: 2,
        poolWaitMs: 10_000,
      },
      sslOff: [false, false, false],
      sslOn: [true, "allow", "prefer", "verify-full"],
    });
    expect(() => readEnv({ ...base, ENVIO_SIDECAR_PG_SSL_MODE: "sometimes" })).toThrow(
      "ENVIO_SIDECAR_PG_SSL_MODE must be one of disable, require, allow, prefer, verify-full, true, false; got 'sometimes'",
    );
  });
});
