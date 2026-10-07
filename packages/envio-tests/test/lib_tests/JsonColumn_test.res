open Vitest

// A json column holds whatever a document can be, not only an object. A string
// or boolean document has to reach the server as JSON, not as the text or
// boolean it would otherwise render to.

let field = (name, fieldType, ~fieldSchema, ~isPrimaryKey=false) =>
  Table.mkField(name, fieldType, ~fieldSchema, ~isPrimaryKey)

let table = Table.mkTable(
  "documents",
  ~fields=[
    field("id", Table.String, ~fieldSchema=S.string, ~isPrimaryKey=true),
    field("doc", Table.Json, ~fieldSchema=S.json(~validate=false)),
  ],
)

let itemSchema = S.object(s => {
  let dict = Dict.make()
  table
  ->Table.getFields
  ->Array.forEach(field =>
    dict->Dict.set(field.fieldName, s.field(field.fieldName, field.fieldSchema))
  )
  dict
})->S.toUnknown

let documents = [
  ("an-object", JSON.Encode.object(Dict.fromArray([("a", JSON.Encode.int(1))]))),
  ("an-array", JSON.Encode.array([JSON.Encode.int(1), JSON.Encode.bool(true)])),
  ("a-number", JSON.Encode.int(1)),
  ("a-string", JSON.Encode.string(`a "quoted", {braced} value`)),
  ("a-true", JSON.Encode.bool(true)),
  ("a-false", JSON.Encode.bool(false)),
]

describe("A json column", () => {
  Async.it("Stores every shape a document can take", async t => {
    let sql = PgStorage.makeClient()
    let pgSchema = TestPgSchema.make()
    await sql->Sql.batch(`CREATE SCHEMA "${pgSchema}";`)
    await sql->Sql.batch(
      PgStorage.makeCreateTableQuery(table, ~pgSchema, ~isNumericArrayAsText=false),
    )

    await sql->PgStorage.setOrThrow(
      ~items=documents
      ->Array.map(((id, doc)) => {"id": id, "doc": doc})
      ->(Utils.magic: array<{"id": string, "doc": JSON.t}> => array<unknown>),
      ~table,
      ~itemSchema,
      ~pgSchema,
      ~setQueryCache=PgStorage.makeSetQueryCache(),
    )

    let rows: array<{
      "id": string,
      "doc": JSON.t,
    }> = await sql->Sql.query(
      `SELECT "id", "doc" FROM "${pgSchema}"."documents" ORDER BY "id" COLLATE "C";`,
    )
    await sql->TestPgSchema.drop(~pgSchema)
    await sql->Sql.close

    t.expect(rows->Array.map(row => (row["id"], row["doc"]->JSON.stringify))).toStrictEqual([
      ("a-false", "false"),
      ("a-number", "1"),
      ("a-string", `"a \\"quoted\\", {braced} value"`),
      ("a-true", "true"),
      ("an-array", "[1,true]"),
      ("an-object", `{"a":1}`),
    ])
  })
})
