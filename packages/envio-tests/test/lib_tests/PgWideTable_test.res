open Vitest

// An entity wide enough that a batch of the usual size binds more parameters
// than the wire protocol can count. The protocol's field is a signed 16-bit
// integer, so a statement stops at 65535 of them, and the insert that binds a
// parameter per cell reaches that at 132 columns and 500 rows.

let sql = PgStorage.makeClient()
let pgSchema = TestPgSchema.make()

let columnCount = 140
let rows = 501

type column = {name: string, schema: S.t<unknown>, field: Table.fieldOrDerived}

let text = (name, ~isPrimaryKey=false) => {
  name,
  schema: S.string->S.toUnknown,
  field: Table.mkField(name, Table.String, ~fieldSchema=S.string, ~isPrimaryKey),
}

let columns =
  [text("id", ~isPrimaryKey=true)]
  ->Array.concat(Array.fromInitializer(~length=columnCount - 2, index => text(`f${index->Int.toString}`)))
  // An array column is what sends the table down the per-cell path, the one
  // whose parameters are counted.
  ->Array.concat([
    {
      name: "tags",
      schema: S.array(S.string)->S.toUnknown,
      field: Table.mkField(
        "tags",
        Table.String,
        ~fieldSchema=S.array(S.string),
        ~isArray=true,
      ),
    },
  ])

let table = Table.mkTable("wide", ~fields=columns->Array.map(column => column.field))

let itemSchema = S.object(s => {
  let dict = Dict.make()
  columns->Array.forEach(column => dict->Dict.set(column.name, s.field(column.name, column.schema)))
  dict
})->S.toUnknown

let items = Array.fromInitializer(~length=rows, row => {
  let item = Dict.make()
  columns->Array.forEach(column =>
    item->Dict.set(
      column.name,
      switch column.name {
      | "id" => row->Int.toString->(Utils.magic: string => unknown)
      | "tags" => [row->Int.toString]->(Utils.magic: array<string> => unknown)
      | name => `${name}-${row->Int.toString}`->(Utils.magic: string => unknown)
      },
    )
  )
  item
})

Async.beforeAll(async () => {
  await sql->Sql.batch(`CREATE SCHEMA "${pgSchema}";`)
  await sql->Sql.batch(PgStorage.makeCreateTableQuery(table, ~pgSchema, ~isNumericArrayAsText=false))
})

Async.afterAll(async () => {
  await TestPgSchema.drop(sql, ~pgSchema)
  await sql->Sql.close
})

describe("A table with more columns than a batch can bind", () => {
  Async.it("writes every row anyway", async t => {
    await sql->PgStorage.setOrThrow(
      ~items=items->(Utils.magic: array<dict<unknown>> => array<unknown>),
      ~table,
      ~itemSchema,
      ~pgSchema,
      ~setQueryCache=PgStorage.makeSetQueryCache(),
    )

    let written =
      (await sql->Sql.query(PgStorage.makeLoadAllQuery(~pgSchema, ~tableName="wide")))->Array.length

    t.expect(written).toEqual(rows)
  })

  it("takes as many rows as the parameters allow", t => {
    t.expect((
      PgStorage.itemsPerQuery(~columns=2),
      PgStorage.itemsPerQuery(~columns=131),
      PgStorage.itemsPerQuery(~columns=132),
      PgStorage.itemsPerQuery(~columns=1000),
      // Wider than a statement can bind at all: one row at a time is the least
      // wrong thing to try, and the server says the rest.
      PgStorage.itemsPerQuery(~columns=70000),
    )).toEqual((500, 500, 496, 65, 1))
  })
})
