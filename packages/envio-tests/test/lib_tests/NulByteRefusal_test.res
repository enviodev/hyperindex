open Vitest

// What Postgres refuses a NUL byte with, in each of the places one can hide.
//
// The write path recognizes that refusal by its wording and answers it by
// writing the batch again with the NULs stripped, so the wording is part of the
// contract between the client and the storage layer rather than a detail of
// either.

let sql = PgStorage.makeClient()
let pgSchema = TestPgSchema.make()
let nul = String.fromCharCode(0)

let fields = [
  Table.mkField("id", Table.String, ~fieldSchema=S.string, ~isPrimaryKey=true),
  Table.mkField("text", Table.String, ~fieldSchema=S.string),
  Table.mkField("tags", Table.String, ~fieldSchema=S.array(S.string), ~isArray=true),
]
let table = Table.mkTable("nul_bytes", ~fields)
let itemSchema = S.object(s => {
  let dict = Dict.make()
  dict->Dict.set("id", s.field("id", S.string->S.toUnknown))
  dict->Dict.set("text", s.field("text", S.string->S.toUnknown))
  dict->Dict.set("tags", s.field("tags", S.array(S.string)->S.toUnknown))
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

let item = (~id, ~text, ~tags) => {
  let item = Dict.make()
  item->Dict.set("id", id->(Utils.magic: string => unknown))
  item->Dict.set("text", text->(Utils.magic: string => unknown))
  item->Dict.set("tags", tags->(Utils.magic: array<string> => unknown))
  item
}

// The server's own message, or "written" when it took the row.
let write = async item =>
  switch await sql->PgStorage.setOrThrow(
    ~items=[item]->(Utils.magic: array<dict<unknown>> => array<unknown>),
    ~table,
    ~itemSchema,
    ~pgSchema,
    ~setQueryCache=PgStorage.makeSetQueryCache(),
  ) {
  | () => "written"
  | exception exn =>
    switch exn->Utils.prettifyExn {
    | Persistence.StorageError({reason}) =>
      (reason->Utils.prettifyExn->(Utils.magic: exn => {"message": string}))["message"]
    | other => (other->(Utils.magic: exn => {"message": string}))["message"]
    }
  }

let refusal = `invalid byte sequence for encoding "UTF8": 0x00`

describe("A NUL byte reaching Postgres", () => {
  Async.it("is refused in the same words wherever it sits, and survives nowhere", async t => {
    let inId = await write(item(~id=`1${nul}x`, ~text="fine", ~tags=["fine"]))
    let inText = await write(item(~id="2", ~text=`a${nul}b`, ~tags=["fine"]))
    let inArrayElement = await write(item(~id="3", ~text="fine", ~tags=[`a${nul}b`]))

    let stripped = item(~id=`4${nul}x`, ~text=`a${nul}b`, ~tags=[`a${nul}b`])
    [stripped]->PgStorage.removeInvalidUtf8InPlace
    let afterStripping = await write(stripped)

    t.expect((inId, inText, inArrayElement, afterStripping, stripped)).toEqual((
      refusal,
      refusal,
      refusal,
      "written",
      item(~id="4x", ~text="ab", ~tags=["ab"]),
    ))
  })

  // A string a contract's bytes decoded into can hold half a surrogate pair,
  // which is not text any encoding can carry. It is replaced on the way rather
  // than refused, so it is not a case the retry has to answer.
  Async.it("is not what a lone surrogate is: that one is written", async t => {
    let lone = String.fromCharCode(0xd800)

    t.expect(await write(item(~id="5", ~text=`a${lone}b`, ~tags=[`a${lone}b`]))).toEqual("written")
  })
})
