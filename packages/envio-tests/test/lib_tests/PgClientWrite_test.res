open Vitest

// The write path end to end: rows laid into the arena from ReScript, rendered
// into the arrays an unnest insert binds by Rust, and read back as what went in.
// The same rows go in through the driver this replaces, and the two tables have
// to end up holding the same thing.

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

    let sql = PgStorage.makeClient()
    let theirs = await sql->Postgres.beginSql(
      async sql => {
        let _ = await sql->Postgres.unsafe(createTable)
        let _ = await sql->Postgres.preparedUnsafe(
          `INSERT INTO staged_rows ("id", "count", "flag", "amount", "price", "at", "blob", "note")
SELECT * FROM unnest($1::TEXT[],$2::INTEGER[],$3::INTEGER[]::BOOLEAN[],$4::NUMERIC[],$5::NUMERIC[],$6::TIMESTAMP WITH TIME ZONE[],$7::BYTEA[],$8::TEXT[]);`,
          [
            rows->Array.map(row => row.id)->Obj.magic,
            rows->Array.map(row => row.count)->Obj.magic,
            rows->Array.map(row => row.flag ? 1 : 0)->Obj.magic,
            rows->Array.map(row => row.amount->BigInt.toString)->Obj.magic,
            rows->Array.map(row => row.price->BigDecimal.toString)->Obj.magic,
            // The driver infers an array's type from its first element, so a
            // `Date` there would make the whole array a timestamp rather than an
            // array of them. `Utils.Schema.dbDate` renders them for the same reason.
            rows->Array.map(row => row.at->Date.toISOString)->Obj.magic,
            // Same reason, and what `Utils.Bytes.toPgArrayLiteral` is for: the
            // old path built this literal in JavaScript, a character at a time.
            rows
            ->Array.map(row => row.blob)
            ->(Utils.magic: array<Uint8Array.t> => array<unknown>)
            ->Utils.Bytes.toPgArrayLiteral
            ->Obj.magic,
            rows->Array.map(row => row.note->Null.fromOption)->Obj.magic,
          ]->Obj.magic,
        )
        await sql->Postgres.unsafe(readBack)
      },
    )
    await sql->Postgres.endSql

    t.expect(mine->PgClientRead_test.plainRows).toStrictEqual(theirs->PgClientRead_test.plainRows)
  })
})
