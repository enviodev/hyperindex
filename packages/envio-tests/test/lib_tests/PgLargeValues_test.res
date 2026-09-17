open Vitest

// Values far past anything the round-trip fuzzer generates. A megabyte of text
// crosses the boundary in one piece: the staging buffer it is written into has
// to grow to hold it, the statement has to carry it, and reading it back has to
// find the same bytes where the column says they end.

let sql = PgStorage.makeClient()
let pgSchema = TestPgSchema.make()

let bigText = "a1b2c3d4"->String.repeat(140_000)
let bigBytes = Uint8Array.fromLength(700_000)

// Two tables: one the arena stages column by column, one that binds a
// parameter per cell because it has an array column.
let staged = Table.mkTable(
  "large_staged",
  ~fields=[
    Table.mkField("id", Table.String, ~fieldSchema=S.string, ~isPrimaryKey=true),
    Table.mkField("text", Table.String, ~fieldSchema=S.string),
    Table.mkField("blob", Table.Bytea, ~fieldSchema=Utils.Schema.bytes),
  ],
)
let perCell = Table.mkTable(
  "large_per_cell",
  ~fields=[
    Table.mkField("id", Table.String, ~fieldSchema=S.string, ~isPrimaryKey=true),
    Table.mkField("text", Table.String, ~fieldSchema=S.string),
    Table.mkField("blob", Table.Bytea, ~fieldSchema=Utils.Schema.bytes),
    Table.mkField("tags", Table.String, ~fieldSchema=S.array(S.string), ~isArray=true),
  ],
)

type row = {id: string, text: string, blob: Uint8Array.t, tags: option<array<string>>}

let itemSchema = (~withTags) =>
  S.object(s => {
    let dict = Dict.make()
    dict->Dict.set("id", s.field("id", S.string->S.toUnknown))
    dict->Dict.set("text", s.field("text", S.string->S.toUnknown))
    dict->Dict.set("blob", s.field("blob", Utils.Schema.bytes->S.toUnknown))
    if withTags {
      dict->Dict.set("tags", s.field("tags", S.array(S.string)->S.toUnknown))
    }
    dict
  })->S.toUnknown

Async.beforeAll(async () => {
  for index in 0 to bigBytes->TypedArray.length - 1 {
    bigBytes->TypedArray.set(index, mod(index * 7 + 11, 256))
  }
  await sql->Sql.batch(`CREATE SCHEMA "${pgSchema}";`)
  await sql->Sql.batch(
    PgStorage.makeCreateTableQuery(staged, ~pgSchema, ~isNumericArrayAsText=false),
  )
  await sql->Sql.batch(
    PgStorage.makeCreateTableQuery(perCell, ~pgSchema, ~isNumericArrayAsText=false),
  )
})

Async.afterAll(async () => {
  await TestPgSchema.drop(sql, ~pgSchema)
  await sql->Sql.close
})

let roundTrip = async (~table: Table.table, ~withTags) => {
  let item = Dict.make()
  item->Dict.set("id", "1"->(Utils.magic: string => unknown))
  item->Dict.set("text", bigText->(Utils.magic: string => unknown))
  item->Dict.set("blob", bigBytes->(Utils.magic: Uint8Array.t => unknown))
  if withTags {
    item->Dict.set("tags", [bigText]->(Utils.magic: array<string> => unknown))
  }

  await sql->PgStorage.setOrThrow(
    ~items=[item]->(Utils.magic: array<dict<unknown>> => array<unknown>),
    ~table,
    ~itemSchema=itemSchema(~withTags),
    ~pgSchema,
    ~setQueryCache=PgStorage.makeSetQueryCache(),
  )

  let rows =
    (await sql->Sql.query(PgStorage.makeLoadAllQuery(~pgSchema, ~tableName=table.tableName)))
    ->(Utils.magic: array<unknown> => array<unknown>)
    ->S.parseOrThrow(table->Table.pgRowsSchema)
    ->(Utils.magic: array<unknown> => array<row>)

  switch rows {
  | [row] => (
      row.text === bigText,
      row.blob->TypedArray.length,
      row.blob->TypedArray.get(699_999),
      row.tags,
    )
  | _ => (false, -1, None, None)
  }
}

describe("A value of a size the fuzzer never reaches", () => {
  Async.it("comes back whole from the table the arena stages", async t => {
    t.expect(await roundTrip(~table=staged, ~withTags=false)).toEqual((
      true,
      700_000,
      Some(bigBytes->TypedArray.get(699_999)->Option.getOr(0)),
      None,
    ))
  })

  Async.it("comes back whole from the table that binds a parameter per cell", async t => {
    t.expect(await roundTrip(~table=perCell, ~withTags=true)).toEqual((
      true,
      700_000,
      Some(bigBytes->TypedArray.get(699_999)->Option.getOr(0)),
      Some([bigText]),
    ))
  })
})
