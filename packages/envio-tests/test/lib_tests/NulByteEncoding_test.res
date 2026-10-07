open Vitest

// Postgres takes a NUL byte in no text value and in no jsonb document, and one
// arrives whenever a contract's bytes are read as text. It is left out on the
// way to the server, wherever it sits, so the rest of the value is stored.

let sql = PgStorage.makeClient()
let pgSchema = TestPgSchema.make()
let nul = String.fromCharCode(0)

let fields = [
  Table.mkField("id", Table.String, ~fieldSchema=S.string, ~isPrimaryKey=true),
  Table.mkField("text", Table.String, ~fieldSchema=S.string),
  Table.mkField("tags", Table.String, ~fieldSchema=S.array(S.string), ~isArray=true),
  Table.mkField("document", Table.Json, ~fieldSchema=S.json(~validate=false)),
]
let table = Table.mkTable("nul_bytes", ~fields)
let itemSchema = S.object(s => {
  let dict = Dict.make()
  dict->Dict.set("id", s.field("id", S.string->S.toUnknown))
  dict->Dict.set("text", s.field("text", S.string->S.toUnknown))
  dict->Dict.set("tags", s.field("tags", S.array(S.string)->S.toUnknown))
  dict->Dict.set("document", s.field("document", S.json(~validate=false)->S.toUnknown))
  dict
})->S.toUnknown

Async.beforeAll(async () => {
  await sql->Sql.batch(`CREATE SCHEMA "${pgSchema}";`)
  await sql->Sql.batch(
    PgStorage.makeCreateTableQuery(table, ~pgSchema, ~isNumericArrayAsText=false),
  )
})

Async.afterAll(async () => {
  await TestPgSchema.drop(sql, ~pgSchema)
  await sql->Sql.close
})

type row = {id: string, text: string, tags: array<string>, document: JSON.t}

describe("A NUL byte reaching Postgres", () => {
  Async.it("is left out wherever it sits, and only it", async t => {
    let document: JSON.t = %raw(`{"deep": "in\u0000side", "k\u0000ey": ["a\u0000b"], "escaped": "\\u0000"}`)
    await sql->PgStorage.setOrThrow(
      ~items=[{id: `1${nul}x`, text: `a${nul}b`, tags: [`c${nul}d`, "plain"], document}]->(
        Utils.magic: array<row> => array<unknown>
      ),
      ~table,
      ~itemSchema,
      ~pgSchema,
      ~setQueryCache=PgStorage.makeSetQueryCache(),
    )

    let rows: array<row> = await sql->Sql.query(
      `SELECT "id", "text", "tags", "document" FROM "${pgSchema}"."nul_bytes";`,
    )
    t.expect(rows).toEqual([
      {
        id: "1x",
        text: "ab",
        tags: ["cd", "plain"],
        document: %raw(`{"deep": "inside", "key": ["ab"], "escaped": "\\u0000"}`),
      },
    ])
  })

  // A string a contract's bytes decoded into can hold half a surrogate pair,
  // which is not text any encoding can carry. It is replaced on the way rather
  // than refused.
  Async.it("is not what a lone surrogate is: that one is written", async t => {
    let lone = String.fromCharCode(0xd800)
    await sql->PgStorage.setOrThrow(
      ~items=[
        {
          id: "2",
          text: `a${lone}b`,
          tags: [`a${lone}b`],
          document: JSON.Encode.object(Dict.make()),
        },
      ]->(Utils.magic: array<row> => array<unknown>),
      ~table,
      ~itemSchema,
      ~pgSchema,
      ~setQueryCache=PgStorage.makeSetQueryCache(),
    )
    let rows: array<{
      "id": string,
    }> = await sql->Sql.query(`SELECT "id" FROM "${pgSchema}"."nul_bytes" WHERE "id" = '2';`)
    t.expect(rows).toEqual([{"id": "2"}])
  })
})
