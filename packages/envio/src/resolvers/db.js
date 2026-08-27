// The `db` handle a resolver's handler is given.
//
// Three things it owns that a bare postgres client does not:
//
//   1. A `statement_timeout` on every query, taken from the resolver's own
//      `timeoutMs`. The resolver process connects around PgBouncer, and a
//      pooler's `query_timeout` drops the client without cancelling the
//      backend — so this is the only thing that actually bounds a runaway
//      query, and a handle cannot be made without one.
//   2. A bounded pool with a bounded *wait*, sized as concurrent heavy
//      requests x per-request fan-out rather than by CPU count: a single
//      resolver holding four connections at once is the shape this exists for.
//   3. Entity loaders that go through the indexer's own table definitions, so
//      what a resolver reads matches what a handler wrote.
//
// SQL construction and row decoding live in `ResolverQuery.res` because both
// are driven by those table definitions.

import postgres from "postgres";
import { warn as logWarn } from "../Logging.res.mjs";
import {
  decodeChainHeights,
  decodeRows,
  makeChainHeightsQuery,
  makeFindQuery,
  makeGetQuery,
} from "./ResolverQuery.res.mjs";

// Design §7.7: concurrent heavy requests x per-request fan-out, not serve's
// `min(cpus*2, 10)`. The fan-out arithmetic is sound; the tail latency it
// assumes is not measured, so the first real workload should re-derive it.
const DEFAULT_POOL_SIZE = 25;

const DEFAULT_POOL_WAIT_TIMEOUT_MS = 10_000;

export class ResolverDbError extends Error {
  constructor(message, code) {
    super(message);
    this.name = "ResolverDbError";
    this.code = code;
  }
}

// Bounds concurrency in front of the driver rather than inside it. postgres.js
// queues indefinitely once its pool is full; a resolver answering a request
// needs the wait itself bounded, so a saturated pool fails that field cleanly
// instead of holding the whole operation open.
class Gate {
  constructor(size) {
    this.size = size;
    this.inUse = 0;
    this.peakInUse = 0;
    this.queue = [];
  }

  take() {
    this.inUse++;
    if (this.inUse > this.peakInUse) {
      this.peakInUse = this.inUse;
    }
  }

  acquire(waitMs) {
    if (this.inUse < this.size) {
      this.take();
      return Promise.resolve();
    }
    return new Promise((resolve, reject) => {
      const entry = { resolve, timer: null };
      entry.timer = setTimeout(() => {
        const index = this.queue.indexOf(entry);
        if (index !== -1) {
          this.queue.splice(index, 1);
        }
        reject(
          new ResolverDbError(
            `Timed out after ${waitMs}ms waiting for one of the resolver pool's ${this.size} connections.`,
            "POOL_WAIT_TIMEOUT"
          )
        );
      }, waitMs);
      this.queue.push(entry);
    });
  }

  release() {
    this.inUse--;
    const next = this.queue.shift();
    if (next) {
      clearTimeout(next.timer);
      this.take();
      next.resolve();
    }
  }
}

function requirePositiveInt(value, describe) {
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value <= 0) {
    throw new ResolverDbError(describe, "INVALID_OPTION");
  }
  return value;
}

/**
 * Opens the resolver process's database pool. One per process: the handles
 * `forResolver` hands out share its connections and its bound on them.
 */
export function createResolverPool(options) {
  if (!options || typeof options !== "object") {
    throw new ResolverDbError(
      "createResolverPool expects an options object",
      "INVALID_OPTION"
    );
  }
  const { connection, entities, pgSchema, poolerBacked, onWarn } = options;

  if (!connection || typeof connection !== "object") {
    throw new ResolverDbError(
      "createResolverPool requires a `connection` with host, port, username, password and database",
      "INVALID_OPTION"
    );
  }
  if (!entities || typeof entities !== "object") {
    throw new ResolverDbError(
      "createResolverPool requires `entities`, the project's entity configs keyed by name",
      "INVALID_OPTION"
    );
  }
  if (typeof pgSchema !== "string" || pgSchema.length === 0) {
    throw new ResolverDbError(
      "createResolverPool requires a `pgSchema`",
      "INVALID_OPTION"
    );
  }

  const poolSize = requirePositiveInt(
    options.poolSize ?? DEFAULT_POOL_SIZE,
    "createResolverPool `poolSize` must be a positive whole number"
  );
  const poolWaitTimeoutMs = requirePositiveInt(
    options.poolWaitTimeoutMs ?? DEFAULT_POOL_WAIT_TIMEOUT_MS,
    "createResolverPool `poolWaitTimeoutMs` must be a positive whole number"
  );

  // Transaction-mode PgBouncer rejects named prepared statements, so the
  // fallback path gives up plan reuse; the direct `-r` path keeps it. The
  // per-query timeout is `SET LOCAL` on *both* paths, unlike the connection
  // startup option the design allowed for the direct one: a single pool serves
  // every resolver, and each brings its own `timeoutMs`.
  const prepare = poolerBacked !== true;

  const sql = postgres({
    host: connection.host,
    port: connection.port,
    username: connection.username,
    password: connection.password,
    database: connection.database,
    ssl: connection.ssl,
    max: poolSize,
    prepare,
    transform: { undefined: null },
    onnotice: () => {},
  });

  const warn = typeof onWarn === "function" ? onWarn : logWarn;
  const gate = new Gate(poolSize);
  // Kept on the pool, not the handle: a handle is per request, so warning
  // there would repeat the same line for every request a wide resolver serves.
  const warnedResolvers = new Set();
  // One resolver holding a quarter of the pool is the fan-out that breaks
  // naive sizing, and it is silent otherwise: the queries all succeed, right
  // up until concurrent requests turn it into pool-wait timeouts.
  const fanOutWarnAt = Math.max(1, Math.floor(poolSize / 4));

  const entityOrThrow = (entityName) => {
    if (typeof entityName !== "string" || !Object.hasOwn(entities, entityName)) {
      throw new ResolverDbError(
        `Unknown entity '${entityName}'. This project has ${Object.keys(entities)
          .sort()
          .join(", ")}.`,
        "UNKNOWN_ENTITY"
      );
    }
    return entities[entityName];
  };

  const forResolver = (resolver) => {
    const name = resolver?.name;
    if (typeof name !== "string" || name.length === 0) {
      throw new ResolverDbError(
        "forResolver requires the resolver's `name`",
        "INVALID_OPTION"
      );
    }
    const { timeoutMs } = resolver;
    if (
      typeof timeoutMs !== "number" ||
      !Number.isSafeInteger(timeoutMs) ||
      timeoutMs <= 0
    ) {
      throw new ResolverDbError(
        `Resolver '${name}' requires a positive \`timeoutMs\`. The resolver process connects around PgBouncer, so statement_timeout is the only bound on a runaway query.`,
        "MISSING_TIMEOUT"
      );
    }

    // No point waiting longer for a connection than the resolver has left to
    // spend on the query it would run.
    const waitMs = Math.min(poolWaitTimeoutMs, timeoutMs);
    let inFlight = 0;

    const run = async (work) => {
      await gate.acquire(waitMs);
      inFlight++;
      if (inFlight > fanOutWarnAt && !warnedResolvers.has(name)) {
        warnedResolvers.add(name);
        warn(
          `Resolver '${name}' held ${inFlight} of the pool's ${poolSize} connections at once. The pool is sized as concurrent heavy requests x per-request fan-out, so a fan-out this wide needs a larger pool or fewer concurrent queries.`
        );
      }
      try {
        return await sql.begin(async (tx) => {
          // `SET LOCAL` rather than a startup option so the bound is this
          // resolver's own, and so it cannot outlive the transaction onto the
          // next query that checks the connection out.
          await tx.unsafe(`SET LOCAL statement_timeout = ${timeoutMs}`);
          return await work(tx);
        });
      } finally {
        inFlight--;
        gate.release();
      }
    };

    const tagged = (strings, ...values) => run((tx) => tx(strings, ...values));
    tagged.unsafe = (text, params = [], queryOptions) =>
      run((tx) => tx.unsafe(text, params, queryOptions));

    return {
      /** Entities matching `where`, decoded as the handlers see them. */
      find: async (entityName, findOptions) => {
        const entityConfig = entityOrThrow(entityName);
        const query = makeFindQuery({
          entityConfig,
          pgSchema,
          where: findOptions?.where,
          orderBy: findOptions?.orderBy,
          limit: findOptions?.limit,
          offset: findOptions?.offset,
        });
        const rows = await run((tx) =>
          tx.unsafe(query.text, query.params, { prepare })
        );
        return decodeRows(entityConfig, rows);
      },

      /** One entity by id, or null. */
      get: async (entityName, id) => {
        const entityConfig = entityOrThrow(entityName);
        const query = makeGetQuery(entityConfig, pgSchema, id);
        const rows = await run((tx) =>
          tx.unsafe(query.text, query.params, { prepare })
        );
        const decoded = decodeRows(entityConfig, rows);
        return decoded.length === 0 ? null : decoded[0];
      },

      /**
       * The per-chain indexed height, for resolvers that refuse to answer from
       * a stale index. `progressBlock` is what has been processed;
       * `sourceBlock` is where the chain was last seen.
       */
      chainHeights: async () => {
        const query = makeChainHeightsQuery(pgSchema);
        const rows = await run((tx) =>
          tx.unsafe(query.text, query.params, { prepare })
        );
        return decodeChainHeights(rows);
      },

      /** Raw SQL: ``db.sql`select ...` `` or `db.sql.unsafe(text, params)`. */
      sql: tagged,

      /**
       * Several queries on one connection, under one timeout. The `sql` handed
       * to the callback is postgres.js's own, so a fragment built from it can
       * be used in a later query of the same block.
       */
      transaction: (work) => run(work),
    };
  };

  return {
    forResolver,
    stats: () => ({
      poolSize,
      inUse: gate.inUse,
      peakInUse: gate.peakInUse,
      waiting: gate.queue.length,
    }),
    end: () => sql.end(),
  };
}
