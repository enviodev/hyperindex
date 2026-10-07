open Vitest

// Every parameter reaches the server as text, so what a value renders to is
// what gets stored. Among them an array of bytes, an array of bigints and a
// bigint past `int8`.

let bytes = (values): Uint8Array.t => values->Uint8Array.fromArray

let columns = [
  ("text", "TEXT", `a,b{"x"}\\`->(Utils.magic: string => unknown)),
  ("empty", "TEXT", ""->(Utils.magic: string => unknown)),
  ("number", "INTEGER", -7->(Utils.magic: int => unknown)),
  // The statement that binds a parameter per cell sends a boolean field as the
  // JavaScript boolean the entity holds, rather than the number the unnest
  // statement's cast expects.
  ("yes", "BOOLEAN", true->(Utils.magic: bool => unknown)),
  ("no", "BOOLEAN", false->(Utils.magic: bool => unknown)),
  ("float", "DOUBLE PRECISION", 1.5->(Utils.magic: float => unknown)),
  ("big", "NUMERIC", 123456789012345678901234567890n->(Utils.magic: bigint => unknown)),
  ("scaled", "NUMERIC", "1.50"->(Utils.magic: string => unknown)),
  (
    "at",
    "TIMESTAMP WITH TIME ZONE",
    Date.fromTime(1234567890123.0)->(Utils.magic: Date.t => unknown),
  ),
  ("blob", "BYTEA", bytes([0xde, 0x00, 0xad])->(Utils.magic: Uint8Array.t => unknown)),
  ("json", "JSONB", {"a": [1, 2], "b": "}"}->(Utils.magic: {..} => unknown)),
  ("missing", "TEXT", %raw(`null`)),
  (
    "texts",
    "TEXT[]",
    ["a,b"->Null.make, Null.null, ""->Null.make]->(Utils.magic: array<Null.t<string>> => unknown),
  ),
  ("blobs", "BYTEA[]", [bytes([0x01]), bytes([])]->(Utils.magic: array<Uint8Array.t> => unknown)),
  ("bigs", "NUMERIC[]", [1n, 2n]->(Utils.magic: array<bigint> => unknown)),
]

let createTable =
  `CREATE TEMPORARY TABLE params (` ++
  columns
  ->Array.map(((name, pgType, _)) => `"${name}" ${pgType}`)
  ->Array.join(", ") ++ `) ON COMMIT DROP;`

let insert =
  `INSERT INTO params VALUES (` ++
  columns
  ->Array.mapWithIndex(((_, pgType, _), index) => `$${(index + 1)->Int.toString}::${pgType}`)
  ->Array.join(", ") ++ `);`

let readBack = `SELECT * FROM params;`

describe("Binding a parameter", () => {
  Async.it("Stores what each value renders to", async t => {
    let sql = PgStorage.makeClient()
    let rows = await sql->Sql.begin(
      async sql => {
        await sql->Sql.batch(createTable)
        await sql->Sql.exec(insert, ~params=columns->Array.map(((_, _, value)) => value))
        await sql->Sql.query(readBack)
      },
    )
    await sql->Sql.close

    t.expect(
      rows->Array.map(
        row =>
          columns->Array.map(((name, _, _)) => (name, PgValue.shown(row->Dict.getUnsafe(name)))),
      ),
    ).toStrictEqual([
      [
        ("text", `text a,b{"x"}\\`),
        ("empty", "text "),
        ("number", "number -7"),
        ("yes", "boolean true"),
        ("no", "boolean false"),
        ("float", "number 1.5"),
        ("big", "text 123456789012345678901234567890"),
        ("scaled", "text 1.50"),
        ("at", "date 2009-02-13T23:31:30.123Z"),
        ("blob", "bytes de00ad"),
        ("json", `json {"a":[1,2],"b":"}"}`),
        ("missing", "null"),
        // A NULL array element reads back as null, not the string "NULL".
        ("texts", "[text a,b, null, text ]"),
        ("blobs", "[bytes 01, bytes ]"),
        ("bigs", "[text 1, text 2]"),
      ],
    ])
  })
})
