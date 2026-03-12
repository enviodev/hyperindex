import pg from "pg";

// Convert undefined values to null in parameter arrays
// (postgres.js did this with transform: { undefined: Null })
function nullifyParams(values) {
  if (!Array.isArray(values)) return values;
  for (let i = 0; i < values.length; i++) {
    if (values[i] === undefined) values[i] = null;
  }
  return values;
}

// Fast hash for generating stable prepared statement names
function hashQuery(text) {
  let hash = 0;
  for (let i = 0; i < text.length; i++) {
    hash = ((hash << 5) - hash + text.charCodeAt(i)) | 0;
  }
  return "q" + (hash >>> 0).toString(36);
}

function makeQueryFn(queryable) {
  return async function unsafe(text, values, options) {
    if (values !== undefined) {
      const queryConfig = { text, values: nullifyParams(values) };
      if (options && options.prepare) {
        queryConfig.name = hashQuery(text);
      }
      const result = await queryable.query(queryConfig);
      return result.rows;
    }
    const result = await queryable.query(text);
    return result.rows;
  };
}

export default function createPool(config) {
  const poolConfig = {
    host: config.host,
    port: config.port,
    user: config.username,
    password: config.password,
    database: config.database,
    max: config.max,
  };

  if (config.ssl !== undefined) {
    if (config.ssl === "require") {
      poolConfig.ssl = { rejectUnauthorized: false };
    } else if (config.ssl === "verify-full") {
      poolConfig.ssl = { rejectUnauthorized: true };
    } else if (
      config.ssl === "prefer" ||
      config.ssl === "allow" ||
      config.ssl === true
    ) {
      poolConfig.ssl = true;
    } else if (config.ssl === false) {
      poolConfig.ssl = false;
    } else if (typeof config.ssl === "object") {
      poolConfig.ssl = config.ssl;
    }
  }

  const pool = new pg.Pool(poolConfig);

  if (config.onnotice) {
    pool.on("connect", (client) => {
      client.on("notice", (msg) => config.onnotice(msg.message));
    });
  }

  pool.on("error", () => {
    // Prevent unhandled error events from crashing the process.
    // Individual query errors are still propagated through promises.
  });

  const wrapper = {
    unsafe: makeQueryFn(pool),

    async begin(fn) {
      const client = await pool.connect();
      try {
        await client.query("BEGIN");
        const clientWrapper = { unsafe: makeQueryFn(client) };
        const result = await fn(clientWrapper);
        await client.query("COMMIT");
        return result;
      } catch (e) {
        await client.query("ROLLBACK").catch(() => {});
        throw e;
      } finally {
        client.release();
      }
    },

    async end() {
      await pool.end();
    },
  };

  return wrapper;
}
