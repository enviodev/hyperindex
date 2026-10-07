open Vitest

// What the addon's client returns for every shape a column can take: what each
// type's text form parses to, which is what every schema downstream is written
// against.

let client = () =>
  PgClient.make({
    host: Env.Db.host,
    port: Env.Db.port,
    user: Env.Db.user,
    password: Env.Db.password,
    database: Env.Db.database,
    ssl: "false",
    maxConnections: 2,
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
  Async.it("Reads every scalar column as its text form parses", async t => {
    let pg = client()
    let rows = await pg->PgClient.query(scalarQuery)
    await pg->PgClient.close
    t.expect(rows->PgValue.rows).toStrictEqual([
      [
        ("a_text", "text plain"),
        ("an_empty_text", "text "),
        ("a_unicode_text", "text h\u{e9}llo \u{1F600}"),
        ("an_int4", "number 42"),
        ("an_int2", "number -7"),
        // Past what a double holds exactly, so it stays text rather than
        // becoming 9007199254740992.
        ("a_wide_int8", "text 9007199254740993"),
        ("a_float8", "number 1.5"),
        ("a_numeric", "text 1.25"),
        // The trailing zero the column's scale gives it, kept digit for digit.
        ("a_scaled_numeric", "text 1.50"),
        ("a_true", "boolean true"),
        ("a_false", "boolean false"),
        // The query's literal is an escaped backslash followed by
        // `xdeadbeef`, so these are the characters of that text.
        ("some_bytes", "bytes 5c786465616462656566"),
        ("no_bytes", "bytes 5c78"),
        ("a_null_text", "null"),
        ("a_null_numeric", "null"),
        ("a_null_bytea", "null"),
        ("a_timestamp", "date 2009-02-13T23:31:30.123Z"),
        ("a_date", "date 1970-01-01T00:00:00.000Z"),
        ("a_document", `json {"a":[1,true,null]}`),
      ],
    ])
  })

  Async.it("Makes the same of an array column", async t => {
    let pg = client()
    let rows = await pg->PgClient.query(arrayQuery)
    await pg->PgClient.close
    t.expect(rows->PgValue.rows).toStrictEqual([
      [
        ("texts", "[text a, text bb]"),
        ("no_texts", "[]"),
        ("ints", "[number 1, number 2, number 3]"),
        ("a_null_array", "null"),
      ],
    ])
  })

  // A query matching nothing still has to name its columns, or the caller has
  // nothing to build over.
  Async.it("Returns no rows without losing the shape of them", async t => {
    let pg = client()
    let rows = await pg->PgClient.query(`SELECT 1::int4 AS a, ARRAY['x']::text[] AS b WHERE false`)
    await pg->PgClient.close
    t.expect(rows).toStrictEqual([])
  })

  Async.it("Carries a bound parameter and reads the row it selects", async t => {
    let pg = client()
    let rows = await pg->PgClient.query(
      `SELECT $1::text AS given`,
      ~params=[Null.make("with 'quotes' and \\ backslash")],
    )
    await pg->PgClient.close
    t.expect(rows->PgValue.rows).toStrictEqual([[("given", "text with 'quotes' and \\ backslash")]])
  })
})

describe("Running statements in a transaction", () => {
  Async.it("Commits what the body did and reads it back", async t => {
    let pg = client()
    let rows = await pg->PgClient.transaction(
      async handle => {
        await pg->PgClient.batch(
          ~transaction=Null.make(handle),
          "CREATE TEMPORARY TABLE committed_here (n int4) ON COMMIT DROP",
        )
        let _ = await pg->PgClient.execute(
          ~transaction=Null.make(handle),
          "INSERT INTO committed_here VALUES ($1::int4)",
          [Null.make("7")],
        )
        await pg->PgClient.query(~transaction=Null.make(handle), "SELECT n FROM committed_here")
      },
    )
    await pg->PgClient.close
    t.expect(rows->PgValue.rows).toStrictEqual([[("n", "number 7")]])
  })

  // The transaction holds a connection until it ends, so a body that throws has
  // to roll back rather than leave it held.
  Async.it("Rolls back when the body throws, and reports what the body threw", async t => {
    let pg = client()
    let thrown = switch await pg->PgClient.transaction(
      async handle => {
        await pg->PgClient.batch(
          ~transaction=Null.make(handle),
          "CREATE TEMPORARY TABLE undone_here (n int4)",
        )
        JsError.throwWithMessage("the body gave up")
      },
    ) {
    | _ => None
    | exception exn =>
      Some(
        exn
        ->Utils.prettifyExn
        ->(Utils.magic: exn => {"message": string})
        ->(error => error["message"]),
      )
    }

    // The table went with the transaction, and the connection came back:
    // another statement on the same client would block otherwise.
    let rows = await pg->PgClient.query(`SELECT to_regclass('pg_temp.undone_here') IS NULL AS gone`)
    await pg->PgClient.close
    t.expect((thrown, rows->PgValue.rows)).toStrictEqual((
      Some("the body gave up"),
      [[("gone", "boolean true")]],
    ))
  })
})

describe("A failure the server raised", () => {
  // The message is in the server's `lc_messages`; the SQLSTATE is the same in
  // every language, so it is what a caller tells failures apart by.
  Async.it("Carries the server's SQLSTATE", async t => {
    let pg = client()
    let code = try {
      let _ = await pg->PgClient.query("SELECT 1 FROM nothing_is_here")
      None
    } catch {
    | exn => Sql.sqlState(exn)
    }
    await pg->PgClient.close
    t.expect(code).toEqual(Some("42P01"))
  })
})

describe("Lending a result's buffers", () => {
  Async.it("Keeps the result alive when it is lent a second time", async t => {
    let pg = client()
    let result = await pg->PgClient.queryRaw(~transaction=Null.null, "SELECT 'x'::text AS a", [])
    let buffers = pg->PgClient.lendResult(result.handle)
    let lentAgain = try {
      let _ = pg->PgClient.lendResult(result.handle)
      true
    } catch {
    | _ => false
    }
    pg->PgClient.releaseResult(result.handle, buffers)
    await pg->PgClient.close
    t.expect((lentAgain, buffers->Array.map(ArrayBuffer.byteLength))).toEqual((
      false,
      buffers->Array.map(_ => 0),
    ))
  })
})

describe("Writing a staged batch", () => {
  Async.it("Refuses a batch that was never committed, and can still abort it", async t => {
    let pg = client()
    let table =
      pg->PgClient.registerWriteTable(
        {tableName: "never_committed", columns: [{name: "id", fieldType: "String"}]},
        ~pgSchema="public",
        ~appendOnly=true,
        ~chainIdMode="int32",
      )
    let {handle, buffers} = pg->PgClient.beginStage(~table=table.handle, ~rows=1)
    let refused = try {
      await pg->PgClient.executeStaged(~transaction=Null.null, ~handle)
      false
    } catch {
    | _ => true
    }
    pg->PgClient.abortStage(~handle, ~buffers)
    await pg->PgClient.close
    t.expect((refused, buffers->Array.map(ArrayBuffer.byteLength))).toEqual((
      true,
      buffers->Array.map(_ => 0),
    ))
  })
})

describe("Reading a bytea column", () => {
  Async.it("Keeps only the bytes the rows hold", async t => {
    let pg = client()
    let rows = await pg->PgClient.query(`SELECT '\\xdead'::bytea AS b UNION ALL SELECT '\\xbeef'::bytea`)
    await pg->PgClient.close
    let retained = rows->Array.map(
      row =>
        row
        ->Dict.getUnsafe("b")
        ->(Utils.magic: unknown => Uint8Array.t)
        ->TypedArray.buffer
        ->ArrayBuffer.byteLength,
    )
    t.expect(retained).toEqual([4, 4])
  })
})
