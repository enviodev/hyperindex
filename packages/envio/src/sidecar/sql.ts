import postgres from "postgres";
import { MAX_SQL_TIMEOUT_MS, type SidecarSqlEnv } from "./env.js";
import type { SidecarLogger } from "./log.js";
import type { MetricsRegistry } from "./metrics.js";

/** A schema qualified, quoted table name from `sql.table()`, only meaningful inside a `sql` template. */
export type SidecarSqlFragment = { readonly __sidecarSqlFragment: true };

export type SidecarSqlRows = readonly object[];

/** What a function, job or route gets as `sql`, and a transaction as `tx`. */
export type SidecarSqlQuery = {
  /** Values are always sent as parameters, never spliced into the text. */
  <T extends SidecarSqlRows = Record<string, unknown>[]>(strings: TemplateStringsArray, ...values: unknown[]): Promise<T>;
  table: (name: string) => SidecarSqlFragment;
  /** `params` is required, even empty: it keeps the query to one statement. */
  unsafe: <T extends SidecarSqlRows = Record<string, unknown>[]>(text: string, params: readonly unknown[]) => Promise<T>;
  readonly schema: string;
  readonly enabled: boolean;
};

export type SidecarSqlTransactionOptions = {
  /** statement_timeout for every statement of the transaction, at most 60000. */
  readonly timeoutMs?: number;
};

export type SidecarSql = SidecarSqlQuery & {
  /** One REPEATABLE READ, READ ONLY transaction: every query in `work` sees the same snapshot. */
  transaction: <T>(work: (tx: SidecarSqlQuery) => Promise<T>, options?: SidecarSqlTransactionOptions) => Promise<T>;
};

/** The runtime's own handle: `SidecarSql` plus the pool's lifecycle. */
export type SidecarSqlHandle = SidecarSql & {
  readonly stats: () => { readonly poolSize: number; readonly inUse: number; readonly waiting: number };
  /** Closes the pool, letting running queries finish for up to `timeoutMs` (default 5000). */
  readonly end: (timeoutMs?: number) => Promise<void>;
};

export type SidecarSqlErrorCode =
  | "POOL_WAIT_TIMEOUT"
  | "STATEMENT_TIMEOUT"
  | "READ_ONLY"
  | "INVALID_ARGUMENT"
  | "QUERY_FAILED";

export class SidecarSqlError extends Error {
  override readonly name = "SidecarSqlError";
  readonly code: SidecarSqlErrorCode;
  /** Postgres' SQLSTATE when the database refused the query. */
  readonly sqlState: string | undefined;
  constructor(code: SidecarSqlErrorCode, message: string, options: { sqlState?: string; cause?: unknown } = {}) {
    super(message, options.cause === undefined ? undefined : { cause: options.cause });
    this.code = code;
    this.sqlState = options.sqlState;
  }
}

export class SidecarSqlDisabledError extends Error {
  override readonly name = "SidecarSqlDisabledError";
  constructor() {
    super(
      "sql is not available: it needs ENVIO_SIDECAR_PG_HOST, _USER and _DATABASE, which are set only on dedicated " +
        "deployments with ENVIO_SIDECAR_SQL=true, or locally under envio dev",
    );
  }
}

export const LARGE_RESULT_ROWS = 10_000;

type Outcome = "ok" | "timeout" | "pool_timeout" | "read_only" | "error";

// Bounds concurrency in front of postgres.js, which queues forever once its
// pool is full: a saturated pool fails the call after `waitMs` instead.
class Gate {
  inUse = 0;
  readonly queue: Array<{ resolve: () => void; timer: NodeJS.Timeout }> = [];
  constructor(readonly size: number) {}

  acquire(waitMs: number): Promise<void> {
    if (this.inUse < this.size) {
      this.inUse++;
      return Promise.resolve();
    }
    return new Promise((resolve, reject) => {
      const entry = {
        resolve,
        timer: setTimeout(() => {
          const index = this.queue.indexOf(entry);
          if (index !== -1) this.queue.splice(index, 1);
          reject(
            new SidecarSqlError(
              "POOL_WAIT_TIMEOUT",
              `Timed out after ${waitMs} ms waiting for one of the sql pool's ${this.size} connections`,
            ),
          );
        }, waitMs),
      };
      this.queue.push(entry);
    });
  }

  release() {
    const next = this.queue.shift();
    if (next === undefined) {
      this.inUse--;
      return;
    }
    clearTimeout(next.timer);
    next.resolve();
  }
}

const quoteIdentifier = (name: string) => `"${name.replace(/"/g, '""')}"`;

const isTemplate = (strings: unknown): strings is TemplateStringsArray =>
  Array.isArray(strings) && Array.isArray((strings as { raw?: unknown }).raw);

const errorCode = (error: unknown): unknown =>
  typeof error === "object" && error !== null ? (error as { code?: unknown }).code : undefined;

// Errors from the driver or the database get a code; anything else (a user's
// own throw inside a transaction) passes through as it is.
const toSqlError = (error: unknown, timeoutMs: number): unknown => {
  if (error instanceof SidecarSqlError) return error;
  if (error instanceof postgres.PostgresError) {
    if (error.code === "57014") {
      return new SidecarSqlError("STATEMENT_TIMEOUT", `Query exceeded the ${timeoutMs} ms statement_timeout`, {
        sqlState: error.code,
        cause: error,
      });
    }
    if (error.code === "25006") {
      return new SidecarSqlError("READ_ONLY", `sql is read only: ${error.message}`, { sqlState: error.code, cause: error });
    }
    return new SidecarSqlError("QUERY_FAILED", error.message, { sqlState: error.code, cause: error });
  }
  const code = errorCode(error);
  // postgres.js connection failures (CONNECT_TIMEOUT, CONNECTION_CLOSED, ...) and socket errnos.
  if (error instanceof Error && typeof code === "string" && (code.startsWith("CONNECT") || "errno" in error)) {
    return new SidecarSqlError("QUERY_FAILED", error.message, { cause: error });
  }
  return error;
};

const outcomeOf = (error: unknown): Outcome => {
  if (!(error instanceof SidecarSqlError)) return "error";
  switch (error.code) {
    case "STATEMENT_TIMEOUT":
      return "timeout";
    case "POOL_WAIT_TIMEOUT":
      return "pool_timeout";
    case "READ_ONLY":
      return "read_only";
    default:
      return "error";
  }
};

const rejectWith = (error: Error) => Promise.reject(error);

export const disabledSidecarSql = (schema = "public"): SidecarSqlHandle => {
  const fail = () => rejectWith(new SidecarSqlDisabledError());
  const query = (() => fail()) as unknown as SidecarSqlHandle;
  return Object.assign(query, {
    table: () => {
      throw new SidecarSqlDisabledError();
    },
    unsafe: fail,
    transaction: fail,
    schema,
    enabled: false,
    stats: () => ({ poolSize: 0, inUse: 0, waiting: 0 }),
    end: () => Promise.resolve(),
  });
};

export type CreateSidecarSqlOptions = {
  readonly log?: SidecarLogger;
  /** Registers envio_sidecar_sql_* series on the runtime's /metrics. */
  readonly metrics?: MetricsRegistry;
};

/** A read-only handle over a bounded pool, or a disabled one when `config` is undefined. */
export const createSidecarSql = (
  config: SidecarSqlEnv | undefined,
  options: CreateSidecarSqlOptions = {},
): SidecarSqlHandle => {
  if (config === undefined) return disabledSidecarSql();
  const { log, metrics } = options;
  const gate = new Gate(config.poolSize);
  const pg = postgres({
    host: config.host,
    port: config.port,
    database: config.database,
    username: config.user,
    ...(config.password === undefined ? {} : { password: config.password }),
    ssl: config.ssl,
    max: config.poolSize,
    // statement_timeout bounds a query, not the connect in front of it.
    connect_timeout: Math.ceil(config.poolWaitMs / 1_000),
    // A transaction-mode pooler rejects named prepared statements.
    prepare: !config.poolerBacked,
    transform: { undefined: null },
    onnotice: () => {},
    connection: { application_name: "envio-sidecar" },
  });

  const queriesTotal = metrics?.counter(
    "envio_sidecar_sql_queries_total",
    "sql calls by outcome (ok, timeout, pool_timeout, read_only, error).",
  );
  const querySeconds = metrics?.histogram(
    "envio_sidecar_sql_query_seconds",
    "Time a sql call held its connection, transactions included.",
  );
  metrics?.gauge("envio_sidecar_sql_pool_in_use", "sql pool connections in use.", () => [[{}, gate.inUse]]);

  const warnedLarge = new Set<string>();
  const checkSize = (key: string, rows: unknown) => {
    if (!Array.isArray(rows) || rows.length <= LARGE_RESULT_ROWS || warnedLarge.has(key)) return;
    warnedLarge.add(key);
    log?.warn(`sql query returned ${rows.length} rows, over ${LARGE_RESULT_ROWS}: page it or aggregate in SQL`, {
      query: key.slice(0, 500),
    });
  };

  const table = (name: string): SidecarSqlFragment => {
    if (typeof name !== "string" || name === "") {
      throw new SidecarSqlError("INVALID_ARGUMENT", "sql.table(name) needs a table name");
    }
    // An unsafe query is never run here: interpolated into a template,
    // postgres.js inlines its text as a fragment.
    return pg.unsafe(`${quoteIdentifier(config.schema)}.${quoteIdentifier(name)}`) as unknown as SidecarSqlFragment;
  };

  const timeoutOf = (requested: number | undefined): number => {
    if (requested === undefined) return config.timeoutMs;
    if (!Number.isInteger(requested) || requested < 1) {
      throw new SidecarSqlError("INVALID_ARGUMENT", `timeoutMs must be a positive integer, got ${String(requested)}`);
    }
    return Math.min(requested, MAX_SQL_TIMEOUT_MS);
  };

  // Every call is its own READ ONLY transaction: the role can be relied on
  // for nothing, and SET LOCAL holds behind a transaction-mode pooler too,
  // where startup GUCs are rejected.
  const run = async <T>(
    mode: string,
    timeoutMs: number,
    work: (tx: postgres.TransactionSql) => Promise<T>,
  ): Promise<T> => {
    let startedAt: number | undefined;
    try {
      await gate.acquire(config.poolWaitMs);
      startedAt = performance.now();
      try {
        const result = await pg.begin(mode, async (tx) => {
          await tx.unsafe(`SET LOCAL statement_timeout = ${timeoutMs}`);
          return work(tx);
        });
        queriesTotal?.inc({ outcome: "ok" });
        return result as T;
      } finally {
        gate.release();
      }
    } catch (error) {
      const mapped = toSqlError(error, timeoutMs);
      queriesTotal?.inc({ outcome: outcomeOf(mapped) });
      throw mapped;
    } finally {
      if (startedAt !== undefined) querySeconds?.observe({}, (performance.now() - startedAt) / 1_000);
    }
  };

  // The statements a handle runs, against the pool (one transaction each) or
  // inside a transaction's `tx`.
  const statements = (
    exec: <T>(timeoutMs: number, work: (tx: postgres.TransactionSql) => Promise<T>) => Promise<T>,
    timeoutMs: number,
  ) => {
    const tagged = (strings: TemplateStringsArray, ...values: unknown[]): Promise<SidecarSqlRows> => {
      if (!isTemplate(strings)) {
        return rejectWith(
          new SidecarSqlError("INVALID_ARGUMENT", "sql is a tagged template: sql`select ...`, not sql(...)"),
        );
      }
      return exec(timeoutMs, async (tx) => {
        // postgres.js' TransactionSql type drops the call signature the object has.
        const rows = await (tx as unknown as postgres.Sql)(strings, ...(values as postgres.ParameterOrFragment<never>[]));
        checkSize(strings.join("$?"), rows);
        return rows;
      });
    };
    const unsafe = (text: string, params: readonly unknown[]): Promise<SidecarSqlRows> => {
      if (typeof text !== "string" || !Array.isArray(params)) {
        return rejectWith(
          new SidecarSqlError(
            "INVALID_ARGUMENT",
            "sql.unsafe(text, params) needs the params array, even empty: it keeps the query to one statement",
          ),
        );
      }
      return exec(timeoutMs, async (tx) => {
        // simple: false keeps the extended protocol even with no params, so
        // `select 1; commit; ...` is refused instead of leaving the transaction.
        const rows = await tx.unsafe(text, params as postgres.ParameterOrJSON<never>[], { simple: false } as never);
        checkSize(text, rows);
        return rows;
      });
    };
    return { tagged, unsafe };
  };

  const pooled = statements((timeoutMs, work) => run("read only", timeoutMs, work), config.timeoutMs);

  const transaction = <T>(
    work: (tx: SidecarSqlQuery) => Promise<T>,
    transactionOptions: SidecarSqlTransactionOptions = {},
  ): Promise<T> => {
    if (typeof work !== "function") {
      return rejectWith(new SidecarSqlError("INVALID_ARGUMENT", "sql.transaction(work) needs a function"));
    }
    let timeoutMs: number;
    try {
      timeoutMs = timeoutOf(transactionOptions.timeoutMs);
    } catch (error) {
      return Promise.reject(error);
    }
    return run("isolation level repeatable read read only", timeoutMs, async (pgTx) => {
      const inner = statements(async (ms, step) => {
        try {
          return await step(pgTx);
        } catch (error) {
          throw toSqlError(error, ms);
        }
      }, timeoutMs);
      const tx = Object.assign(inner.tagged, {
        table,
        unsafe: inner.unsafe,
        schema: config.schema,
        enabled: true,
      }) as unknown as SidecarSqlQuery;
      return work(tx);
    });
  };

  return Object.assign(pooled.tagged, {
    table,
    unsafe: pooled.unsafe,
    transaction,
    schema: config.schema,
    enabled: true,
    stats: () => ({ poolSize: config.poolSize, inUse: gate.inUse, waiting: gate.queue.length }),
    end: (timeoutMs = 5_000) => pg.end({ timeout: Math.max(0, timeoutMs) / 1_000 }),
  }) as unknown as SidecarSqlHandle;
};
