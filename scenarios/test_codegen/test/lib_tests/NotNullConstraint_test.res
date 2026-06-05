open Vitest

// Reproduces the production failure where a handler writes an entity whose
// required (NOT NULL) field is `undefined` at runtime. Because the batch set
// query is compiled with `typeValidation = false` (see PgStorage.makeTableBatchSetQuery),
// Sury never checks that the field is present, and makeClient's
// `transform: {undefined: Null}` turns the missing value into a SQL NULL —
// surfacing only as a cryptic Postgres NOT NULL violation at write time.
//
// Mirrors the reported error: id "1750-undefined" (handler interpolated an
// undefined address into the id) while the `address` column went in as null.
module Token = {
  type t = {
    id: string,
    address: string,
    chainId: int,
  }

  let schema = S.schema(s => {
    id: s.matches(S.string),
    address: s.matches(S.string),
    chainId: s.matches(S.int),
  })

  let table = Table.mkTable(
    "Token",
    ~fields=[
      Table.mkField("id", String, ~fieldSchema=S.string, ~isPrimaryKey=true),
      Table.mkField("address", String, ~fieldSchema=S.string, ~isIndex=true),
      Table.mkField("chainId", Int32, ~fieldSchema=S.int, ~isIndex=true),
    ],
  )
}

type reproResult = {
  message: string,
  pgMessage: string,
  pgCode: string,
  pgColumn: string,
}

describe("NOT NULL constraint violation from an undefined required field", () => {
  Async.it(
    "A handler passing `undefined` for a required field fails with a Postgres NOT NULL violation",
    async t => {
      let sql = PgStorage.makeClient()
      let pgSchema = Env.Db.publicSchema

      let _ = await sql->Postgres.unsafe(`DROP TABLE IF EXISTS "${pgSchema}"."Token";`)
      let _ = await sql->Postgres.unsafe(
        PgStorage.makeCreateTableQuery(Token.table, ~pgSchema, ~isNumericArrayAsText=false),
      )

      let setTokens = (items: array<Token.t>) =>
        sql->PgStorage.setOrThrow(~items, ~table=Token.table, ~itemSchema=Token.schema, ~pgSchema)

      // A fully-populated token writes fine — only the undefined field breaks.
      await setTokens([{id: "1750-0xabc", address: "0xabc", chainId: 1750}])

      // Simulate a handler whose `address` resolved to `undefined` (e.g. a
      // failed contract read) yet still got interpolated into the id template.
      let brokenToken =
        %raw(`{id: "1750-undefined", address: undefined, chainId: 1750}`)->(
          Utils.magic: 'a => Token.t
        )

      let result = try {
        await setTokens([brokenToken])
        None
      } catch {
      | Persistence.StorageError({message, reason}) =>
        let pgError =
          reason->(
            Utils.magic: exn => {"message": string, "code": string, "column_name": string}
          )
        Some({
          message,
          pgMessage: pgError["message"],
          pgCode: pgError["code"],
          pgColumn: pgError["column_name"],
        })
      | _ => None
      }

      t.expect(result).toEqual(
        Some({
          message: `Failed to insert items into table "Token"`,
          pgMessage: `null value in column "address" of relation "Token" violates not-null constraint`,
          pgCode: "23502",
          pgColumn: "address",
        }),
      )
    },
  )
})
