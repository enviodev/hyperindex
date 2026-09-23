open Vitest

// What a batch write stores, column type by column type. The values reach the
// server through whatever renders them, so this pins the result rather than the
// route: it is what says the arena path and the one that renders parameters in
// JavaScript put the same thing in the table.

let field = (name, fieldType, ~fieldSchema, ~isNullable=false, ~isPrimaryKey=false) =>
  Table.mkField(name, fieldType, ~fieldSchema, ~isNullable, ~isPrimaryKey)

let fields = [
  field("id", Table.String, ~fieldSchema=S.string, ~isPrimaryKey=true),
  field("n", Table.Int32, ~fieldSchema=S.int),
  field("f", Table.Number, ~fieldSchema=S.float),
  field("flag", Table.Boolean, ~fieldSchema=S.bool),
  field("big", Table.BigInt({}), ~fieldSchema=S.bigint),
  field("dec", Table.BigDecimal({}), ~fieldSchema=BigDecimal.schema),
  field("at", Table.Date, ~fieldSchema=Utils.Schema.dbDate),
  field("blob", Table.Bytea, ~fieldSchema=Utils.Schema.bytes),
  field("note", Table.String, ~fieldSchema=S.null(S.string), ~isNullable=true),
  field("maybe", Table.Int32, ~fieldSchema=S.null(S.int), ~isNullable=true),
]

let table = Table.mkTable("batch_set", ~fields)

let itemSchema = S.object(s => {
  let dict = Dict.make()
  table
  ->Table.getFields
  ->Array.forEach(field =>
    dict->Dict.set(field.fieldName, s.field(field.fieldName, field.fieldSchema))
  )
  dict
})->S.toUnknown

let bytes = (values): Uint8Array.t => values->Uint8Array.fromArray

let items = [
  {
    "id": `a,b{"x"}\\`,
    "n": -7,
    "f": 1.5,
    "flag": true,
    "big": 123456789012345678901234567890n,
    "dec": BigDecimal.fromStringUnsafe("1.50"),
    "at": Date.fromTime(1234567890123.0),
    "blob": bytes([0xde, 0xad, 0x00]),
    "note": Null.make("here"),
    "maybe": Null.make(3),
  },
  {
    "id": "",
    "n": 0,
    "f": 0.,
    "flag": false,
    "big": 0n,
    "dec": BigDecimal.fromStringUnsafe("0"),
    "at": Date.fromTime(0.0),
    "blob": bytes([]),
    "note": Null.null,
    "maybe": Null.null,
  },
]

let createTable = pgSchema =>
  `CREATE TABLE "${pgSchema}"."batch_set" (
  "id" TEXT NOT NULL, "n" INTEGER NOT NULL, "f" DOUBLE PRECISION NOT NULL,
  "flag" BOOLEAN NOT NULL, "big" NUMERIC NOT NULL, "dec" NUMERIC NOT NULL,
  "at" TIMESTAMP WITH TIME ZONE NOT NULL, "blob" BYTEA NOT NULL,
  "note" TEXT, "maybe" INTEGER, PRIMARY KEY ("id")
);`

describe("Writing a batch", () => {
  Async.it("Stores every column type as the column holds it", async t => {
    let sql = PgStorage.makeClient()
    let pgSchema = TestPgSchema.make()
    await sql->Sql.batch(`CREATE SCHEMA "${pgSchema}";`)
    await sql->Sql.batch(createTable(pgSchema))

    await sql->PgStorage.setOrThrow(
      ~items=items->(Utils.magic: array<'a> => array<unknown>),
      ~table,
      ~itemSchema,
      ~pgSchema,
      ~setQueryCache=PgStorage.makeSetQueryCache(),
    )

    let rows = await sql->Sql.query(`SELECT * FROM "${pgSchema}"."batch_set" ORDER BY "n";`)
    await sql->TestPgSchema.drop(~pgSchema)
    await sql->Sql.close

    t.expect(rows->PgValue.rows).toStrictEqual([
      [
        ("id", `text a,b{"x"}\\`),
        ("n", "number -7"),
        ("f", "number 1.5"),
        ("flag", "boolean true"),
        ("big", "text 123456789012345678901234567890"),
        ("dec", "text 1.5"),
        ("at", "date 2009-02-13T23:31:30.123Z"),
        ("blob", "bytes dead00"),
        ("note", "text here"),
        ("maybe", "number 3"),
      ],
      [
        ("id", "text "),
        ("n", "number 0"),
        ("f", "number 0"),
        ("flag", "boolean false"),
        ("big", "text 0"),
        ("dec", "text 0"),
        ("at", "date 1970-01-01T00:00:00.000Z"),
        ("blob", "bytes "),
        ("note", "null"),
        ("maybe", "null"),
      ],
    ])
  })
})
