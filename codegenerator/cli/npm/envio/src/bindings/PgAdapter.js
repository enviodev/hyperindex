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

function getRows(result) {
  return result.rows;
}

/**
 * Creates a connection pool with an API compatible with postgres.js.
 *
 * @param {object} config - Pool configuration
 * @returns {object} sql object with unsafe() and begin() methods
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

  return {
    unsafe: methods.unsafe,

    async begin(callback) {
      const client = await pool.connect();
      try {
        await client.query("BEGIN");
        const txMethods = makeSqlMethods(client);
        const txSql = {
          unsafe: txMethods.unsafe,
          // Nested begin uses savepoints
          async begin(innerCallback) {
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
          },
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
    },

    async end() {
      await pool.end();
    },
  };
}
