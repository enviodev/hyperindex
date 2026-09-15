open Vitest

// The write path end to end: rows laid into the arena from ReScript, rendered
// into the arrays an unnest insert binds by Rust, and read back as what went
// in. The values are pinned against what the driver this replaces stored for
// the same rows.

let field = (name, fieldType, ~isNullable=false, ~isPrimaryKey=false) =>
  Table.mkField(name, fieldType, ~fieldSchema=S.unknown, ~isNullable, ~isPrimaryKey)

// Every slot a staged column can take: a number, text, bytes, and the two that
// reach a text slot as something other than their own text.
let fields = [
  field("id", Table.String, ~isPrimaryKey=true),
  field("count", Table.Int32),
  field("flag", Table.Boolean),
  field("amount", Table.BigInt({})),
  field("price", Table.BigDecimal({})),
  field("at", Table.Date),
  field("blob", Table.Bytea),
  field("note", Table.String, ~isNullable=true),
]

let table = Table.mkTable("staged_rows", ~fields)

let plainFields = table->Table.getFields

type row = {
  id: string,
  count: int,
  flag: bool,
  amount: bigint,
  price: BigDecimal.t,
  at: Date.t,
  blob: Uint8Array.t,
  note: option<string>,
}

let bytes = (values): Uint8Array.t => values->Uint8Array.fromArray

let rows = [
  {
    // Every character an array literal itself reads, so the rendering has to
    // survive its own punctuation.
    id: `a,b{"x"}\\`,
    count: -7,
    flag: true,
    amount: 123456789012345678901234567890n,
    price: BigDecimal.fromStringUnsafe("1.50"),
    at: Date.fromTime(1234567890123.0),
    blob: bytes([0xde, 0xad, 0x00]),
    note: Some("here"),
  },
  {
    id: "",
    count: 0,
    flag: false,
    amount: 0n,
    price: BigDecimal.fromStringUnsafe("0.00"),
    at: Date.fromTime(0.0),
    blob: bytes([]),
    note: None,
  },
]

let client = () =>
  PgClient.make({
    host: Env.Db.host,
    port: Env.Db.port,
    user: Env.Db.user,
    password: Env.Db.password,
    database: Env.Db.database,
    ssl: "false",
    maxConnections: 2,
    applicationName: "envio-write-test",
  })

let createTable = `CREATE TEMPORARY TABLE staged_rows (
  "id" TEXT NOT NULL, "count" INTEGER NOT NULL, "flag" BOOLEAN NOT NULL,
  "amount" NUMERIC NOT NULL, "price" NUMERIC NOT NULL,
  "at" TIMESTAMP WITH TIME ZONE NOT NULL, "blob" BYTEA NOT NULL, "note" TEXT,
  PRIMARY KEY ("id")
) ON COMMIT DROP;`

let readBack = `SELECT "id", "count", "flag", "amount", "price", "at", "blob", "note"
  FROM staged_rows ORDER BY "count";`

describe("Writing a staged batch", () => {
  Async.it("Stores what the driver it replaces would have stored", async t => {
    let pg = client()
    let mine = await pg->PgClient.transaction(
      async handle => {
        await pg->PgClient.transactionBatch(handle, createTable)
        let staged =
          pg
          ->PgClient.arena
          ->PgWriting.stage(
            ~table=pg->PgClient.registerWriteTable(
              plainFields->Array.map(Table.getPgDbFieldName),
              plainFields->Array.map(field => (field.fieldType->PgWriting.slotFor :> int)),
            ),
            ~fields=plainFields,
            ~rows,
          )
        await pg->PgClient.executeStaged(
          ~transaction=Null.make(handle),
          ~sql=Core.pgInsertUnnestQuery(
            ~table={
              tableName: "staged_rows",
              columns: plainFields->Array.map(PgStorage.pgColumnInput),
            },
            ~pgSchema="pg_temp",
            ~appendOnly=false,
            ~chainIdMode="int32",
          ),
          ~handle=staged,
          ~unnest=true,
        )
        await pg->PgClient.transactionQuery(handle, readBack)
      },
    )
    await pg->PgClient.close

    t.expect(mine->PgValue.rows).toStrictEqual([
      [
        ("id", `text a,b{"x"}\\`),
        ("count", "number -7"),
        ("flag", "boolean true"),
        ("amount", "text 123456789012345678901234567890"),
        ("price", "text 1.5"),
        ("at", "date 2009-02-13T23:31:30.123Z"),
        ("blob", "bytes dead00"),
        ("note", "text here"),
      ],
      [
        ("id", "text "),
        ("count", "number 0"),
        ("flag", "boolean false"),
        ("amount", "text 0"),
        ("price", "text 0"),
        ("at", "date 1970-01-01T00:00:00.000Z"),
        ("blob", "bytes "),
        ("note", "null"),
      ],
    ])
  })
})
