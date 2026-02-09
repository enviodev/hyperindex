import pg from "pg";

// Monotonic counter for prepared statement names
let queryCounter = 0;
const queryNames = new Map();

function getQueryName(text) {
  let name = queryNames.get(text);
  if (name === undefined) {
    name = `q${++queryCounter}`;
    queryNames.set(text, name);
  }
  return name;
}

function getRows(result) {
  return result.rows;
}

// Marker symbol for SQL fragments produced by sql(obj)
const SQL_FRAGMENT = Symbol("sqlFragment");

function createInsertHelper(obj) {
  const keys = Object.keys(obj);
  const values = keys.map((k) => obj[k]);
  return {
    [SQL_FRAGMENT]: true,
    values,
    toSql(startIndex) {
      const cols = keys.map((k) => `"${k}"`).join(", ");
      const placeholders = keys
        .map((_, i) => `$${startIndex + i}`)
        .join(", ");
      return `(${cols}) VALUES(${placeholders})`;
    },
  };
}

function makeSqlTaggedTemplate(queryable) {
  // Tagged template literal handler: sql`SELECT ...`
  // Also handles sql(obj) for INSERT helpers
  function sql(strings, ...values) {
    // sql(obj) call — not a tagged template literal
    if (!Array.isArray(strings) || strings.raw === undefined) {
      return createInsertHelper(strings);
    }

    // Tagged template literal: build parameterized query
    let text = "";
    const params = [];
    let paramIndex = 1;

    for (let i = 0; i < strings.length; i++) {
      text += strings[i];
      if (i < values.length) {
        const val = values[i];
        if (val && val[SQL_FRAGMENT]) {
          text += val.toSql(paramIndex);
          params.push(...val.values);
          paramIndex += val.values.length;
        } else {
          text += `$${paramIndex++}`;
          params.push(val);
        }
      }
    }

    if (params.length > 0) {
      return queryable.query(text, params).then(getRows);
    }
    return queryable.query(text).then(getRows);
  }

  return sql;
}

function makeSqlMethods(queryable) {
  return {
    unsafe(query, params, options) {
      if (params !== undefined) {
        if (options !== undefined && options.prepare) {
          return queryable
            .query({ name: getQueryName(query), text: query, values: params })
            .then(getRows);
        }
        return queryable.query(query, params).then(getRows);
      }
      return queryable.query(query).then(getRows);
    },
  };
}

/**
 * Creates a connection pool with an API compatible with postgres.js.
 *
 * @param {object} config - Pool configuration
 * @returns {object} sql object with unsafe() and begin() methods,
 *   also callable as a tagged template literal: sql`SELECT ...`
 */
export default function createPool(config) {
  const pgConfig = {
    host: config.host,
    port: config.port,
    user: config.username,
    password: config.password,
    database: config.database,
    max: config.max,
    application_name:
      config.connection && config.connection.applicationName
        ? config.connection.applicationName
        : undefined,
  };

  // Map SSL options
  if (config.ssl !== undefined) {
    switch (config.ssl) {
      case true:
        pgConfig.ssl = true;
        break;
      case false:
        pgConfig.ssl = false;
        break;
      case "require":
        pgConfig.ssl = { rejectUnauthorized: false };
        break;
      case "allow":
      case "prefer":
        pgConfig.ssl = { rejectUnauthorized: false };
        break;
      case "verify-full":
        pgConfig.ssl = { rejectUnauthorized: true };
        break;
      default:
        // TLS connect options object
        if (typeof config.ssl === "object") {
          pgConfig.ssl = config.ssl;
        }
    }
  }

  // Map timeout options (postgres.js uses seconds, pg uses milliseconds)
  if (config.idleTimeout !== undefined) {
    pgConfig.idleTimeoutMillis = config.idleTimeout * 1000;
  }
  if (config.connectTimeout !== undefined) {
    pgConfig.connectionTimeoutMillis = config.connectTimeout * 1000;
  }

  const pool = new pg.Pool(pgConfig);

  // Handle notice events
  if (typeof config.onnotice === "function") {
    pool.on("notice", (notice) => {
      config.onnotice(notice.message || String(notice));
    });
  }

  const methods = makeSqlMethods(pool);

  // Create the sql tagged template function and attach methods
  const sql = makeSqlTaggedTemplate(pool);
  sql.unsafe = methods.unsafe;

  sql.begin = async function begin(callback) {
    const client = await pool.connect();
    try {
      await client.query("BEGIN");
      const txMethods = makeSqlMethods(client);
      const txSql = makeSqlTaggedTemplate(client);
      txSql.unsafe = txMethods.unsafe;
      // Nested begin uses savepoints
      txSql.begin = async function beginNested(innerCallback) {
        const savepointName = `sp_${Date.now()}`;
        await client.query(`SAVEPOINT ${savepointName}`);
        try {
          const result = await innerCallback(txSql);
          await client.query(`RELEASE SAVEPOINT ${savepointName}`);
          return result;
        } catch (e) {
          await client.query(`ROLLBACK TO SAVEPOINT ${savepointName}`);
          throw e;
        }
      };
      const result = await callback(txSql);
      await client.query("COMMIT");
      return result;
    } catch (e) {
      try {
        await client.query("ROLLBACK");
      } catch (_) {
        // Ignore rollback errors
      }
      throw e;
    } finally {
      client.release();
    }
  };

  sql.end = async function end() {
    await pool.end();
  };

  return sql;
}
