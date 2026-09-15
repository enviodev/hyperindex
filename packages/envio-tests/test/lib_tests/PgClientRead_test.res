open Vitest

// The addon's client against the driver it replaces, on the same query. What
// the old one produced is what every schema downstream is written against, so
// any disagreement here is a value that would change under the migration.
//
// The two differ in how they get the bytes — text out of the driver, binary
// decoded in Rust and laid into the arena — which is exactly why they are
// compared rather than assumed equal.

// The driver builds its rows from a class of its own, so comparing them as they
// come would only ever report the prototype. Copying both sides onto plain
// objects leaves the values — and their types, which is what is being checked —
// alone.
let plainRows: array<'a> => array<'a> = %raw(`rows => rows.map(row => Object.assign({}, row))`)

let client = () =>
  PgClient.make({
    host: Env.Db.host,
    port: Env.Db.port,
    user: Env.Db.user,
    password: Env.Db.password,
    database: Env.Db.database,
    ssl: "false",
    maxConnections: 2,
    applicationName: "envio-read-test",
  })

// Every scalar shape a column can take, in one row.
let scalarQuery = `SELECT
  'plain'::text AS a_text,
  ''::text AS an_empty_text,
  'héllo \u{1F600}'::text AS a_unicode_text,
  42::int4 AS an_int4,
  (-7)::int2 AS an_int2,
  9007199254740993::int8 AS a_wide_int8,
  1.5::float8 AS a_float8,
  1.25::numeric AS a_numeric,
  1.50::numeric(10,2) AS a_scaled_numeric,
  true AS a_true,
  false AS a_false,
  '\\\\xdeadbeef'::bytea AS some_bytes,
  '\\\\x'::bytea AS no_bytes,
  NULL::text AS a_null_text,
  NULL::numeric AS a_null_numeric,
  NULL::bytea AS a_null_bytea,
  '2009-02-13T23:31:30.123Z'::timestamptz AS a_timestamp,
  '1970-01-01'::date AS a_date,
  '{"a":[1,true,null]}'::jsonb AS a_document`

let arrayQuery = `SELECT
  ARRAY['a','bb']::text[] AS texts,
  ARRAY[]::text[] AS no_texts,
  ARRAY[1,2,3]::int4[] AS ints,
  NULL::int4[] AS a_null_array`

describe("Reading a result set through the arena", () => {
  Async.it(
    "Agrees with the driver it replaces on every scalar column",
    async t => {
      let pg = client()
      let sql = PgStorage.makeClient()
      let mine = await pg->PgClient.query(scalarQuery)
      let theirs = await sql->Postgres.unsafe(scalarQuery)
      await pg->PgClient.close
      await sql->Postgres.endSql
      t.expect(mine->plainRows).toStrictEqual(theirs->plainRows)
    },
  )

  Async.it(
    "Agrees with it on array columns too",
    async t => {
      let pg = client()
      let sql = PgStorage.makeClient()
      let mine = await pg->PgClient.query(arrayQuery)
      let theirs = await sql->Postgres.unsafe(arrayQuery)
      await pg->PgClient.close
      await sql->Postgres.endSql
      t.expect(mine->plainRows).toStrictEqual(theirs->plainRows)
    },
  )

  // A query matching nothing still has to name its columns, or the caller has
  // nothing to build over.
  Async.it(
    "Returns no rows without losing the shape of them",
    async t => {
      let pg = client()
      let rows = await pg->PgClient.query(`SELECT 1::int4 AS a, ARRAY['x']::text[] AS b WHERE false`)
      await pg->PgClient.close
      t.expect(rows).toStrictEqual([])
    },
  )

  Async.it(
    "Carries a bound parameter and reads the row it selects",
    async t => {
      let pg = client()
      let rows =
        await pg->PgClient.query(
          `SELECT $1::text AS given`,
          ~params=[Null.make("with 'quotes' and \\ backslash")],
        )
      await pg->PgClient.close
      t.expect(rows).toStrictEqual([{"given": "with 'quotes' and \\ backslash"}->Obj.magic])
    },
  )
})

describe("Running statements in a transaction", () => {
  Async.it(
    "Commits what the body did and reads it back",
    async t => {
      let pg = client()
      let rows = await pg->PgClient.transaction(async handle => {
        await pg->PgClient.transactionBatch(
          handle,
          "CREATE TEMPORARY TABLE committed_here (n int4) ON COMMIT DROP",
        )
        let _ = await pg->PgClient.transactionExecute(
          handle,
          "INSERT INTO committed_here VALUES ($1::int4)",
          [Null.make("7")],
        )
        await pg->PgClient.transactionQuery(handle, "SELECT n FROM committed_here")
      })
      await pg->PgClient.close
      t.expect(rows->plainRows).toStrictEqual([{"n": 7}->Obj.magic])
    },
  )

  // The transaction holds a connection until it ends, so a body that throws has
  // to roll back rather than leave it held.
  Async.it(
    "Rolls back when the body throws, and reports what the body threw",
    async t => {
      let pg = client()
      let thrown = switch await pg->PgClient.transaction(async handle => {
        await pg->PgClient.transactionBatch(handle, "CREATE TEMPORARY TABLE undone_here (n int4)")
        JsError.throwWithMessage("the body gave up")
      }) {
      | _ => None
      | exception exn => Some(
          exn
          ->Utils.prettifyExn
          ->(Utils.magic: exn => {"message": string})
          ->(error => error["message"]),
        )
      }

      // The table went with the transaction, and the connection came back:
      // another statement on the same client would block otherwise.
      let rows = await pg->PgClient.query(
        `SELECT to_regclass('pg_temp.undone_here') IS NULL AS gone`,
      )
      await pg->PgClient.close
      t.expect((thrown, rows->plainRows)).toStrictEqual((
        Some("the body gave up"),
        [{"gone": true}->Obj.magic],
      ))
    },
  )
})
