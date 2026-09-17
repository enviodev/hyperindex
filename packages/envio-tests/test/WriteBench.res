// Not a test: a fixed amount of storage work, with the process's CPU time
// around it. Run on this branch and on the commit before the migration, the
// difference is what moving Postgres into the addon bought.
//
// `process.cpuUsage()` counts every thread of the process, so the work the
// addon does on its own runtime is counted too — the point is the indexer's
// total cost, not which thread paid it.
//
// Two tables, because a batch takes one of two statements and only one of them
// was changed: a table with a date or a json column goes in through the
// statement that binds every cell, and every other table through one unnest per
// column.

@val @scope("process") external cpuUsage: unit => {"user": float, "system": float} = "cpuUsage"
@val @scope(("process", "hrtime")) external now: unit => bigint = "bigint"
@val @scope("console") external log: string => unit = "log"

let field = (name, fieldType, ~fieldSchema, ~isNullable=false, ~isPrimaryKey=false) =>
  Table.mkField(name, fieldType, ~fieldSchema, ~isNullable, ~isPrimaryKey)

// A transfer, which is what most indexers mostly write: an id, two addresses,
// an amount no double holds, a block, a flag.
let sharedFields = [
  field("id", Table.String, ~fieldSchema=S.string, ~isPrimaryKey=true),
  field("sender", Table.Bytea, ~fieldSchema=Utils.Schema.bytes),
  field("receiver", Table.Bytea, ~fieldSchema=Utils.Schema.bytes),
  field("amount", Table.BigInt({}), ~fieldSchema=Utils.BigInt.schema),
  field("block_number", Table.Int32, ~fieldSchema=S.int),
  field("is_burn", Table.Boolean, ~fieldSchema=S.bool),
]

let dateField = field("at", Table.Date, ~fieldSchema=Utils.Schema.dbDate)

let unnested = Table.mkTable("unnested", ~fields=sharedFields)
let valued = Table.mkTable("valued", ~fields=sharedFields->Array.concat([dateField]))

let schemaOf = (table: Table.table) =>
  S.object(s => {
    let dict = Dict.make()
    table
    ->Table.getFields
    ->Array.forEach(field =>
      dict->Dict.set(field.fieldName, s.field(field.fieldName, field.fieldSchema))
    )
    dict
  })->S.toUnknown

let address = seed => {
  let bytes = Uint8Array.fromLength(20)
  for index in 0 to 19 {
    bytes->TypedArray.set(index, mod(seed * 31 + index * 7, 256))
  }
  bytes
}

let batch = (~offset, ~rows, ~withDate) =>
  Array.fromInitializer(~length=rows, index => {
    let n = offset + index
    let row = {
      "id": `0x${n->Int.toString}-${(n * 7)->Int.toString}`,
      "sender": address(n),
      "receiver": address(n + 1),
      // Under what an int8 holds, which is all the statement binding every cell
      // can carry: it sends the value with the type the driver read off it.
      "amount": BigInt.fromInt(n)->BigInt.mul(1000000n),
      "block_number": 18000000 + n / 50,
      "is_burn": mod(n, 7) === 0,
    }
    if withDate {
      row
      ->(Utils.magic: {..} => dict<unknown>)
      ->Dict.set("at", Date.fromTime(1700000000000. +. n->Int.toFloat *. 12000.)->Obj.magic)
    }
    row
  })

let rowsPerBatch = 2000
let batches = 30
let loadsPerRep = 5
let reps = 5

let ms = micros => (micros /. 1000.)->Math.round->Float.toString
let wallMs = (nanos: bigint) => (nanos->BigInt.toFloat /. 1.e6)->Math.round->Float.toString

// One measured stretch: the CPU the process spent, and how long it took.
let measure = async (label, ~work) => {
  let cpuBefore = cpuUsage()
  let wallBefore = now()
  await work()
  let wall = now() - wallBefore
  let cpuAfter = cpuUsage()
  log(
    `${label} wall_ms=${wallMs(wall)} cpu_user_ms=${ms(
        cpuAfter["user"] -. cpuBefore["user"],
      )} cpu_system_ms=${ms(cpuAfter["system"] -. cpuBefore["system"])}`,
  )
}

let run = async () => {
  let pgSchema = "bench"
  let sql = PgStorage.makeClient()
  let setQueryCache = PgStorage.makeSetQueryCache()

  let write = async (~table: Table.table, ~itemSchema, ~withDate, ~offset) =>
    await sql->PgStorage.setOrThrow(
      ~items=batch(~offset, ~rows=rowsPerBatch, ~withDate)->(
        Utils.magic: array<'a> => array<unknown>
      ),
      ~table,
      ~itemSchema,
      ~pgSchema,
      ~setQueryCache,
    )

  let exercise = async (name, ~table: Table.table, ~withDate) => {
    let itemSchema = schemaOf(table)
    let loadAll = PgStorage.makeLoadAllQuery(~pgSchema, ~tableName=table.tableName)

    for rep in 0 to reps - 1 {
      // Every repetition writes into an empty table, so none of them pays for
      // what the ones before it left behind.
      let _ = await sql->BenchAdapter.query(`TRUNCATE "${pgSchema}"."${table.tableName}";`)

      // The first batch compiles the table's converter and prepares the
      // statement, neither of which the batches after it pay for.
      await write(~table, ~itemSchema, ~withDate, ~offset=0)

      await measure(
        `write ${name} rep=${rep->Int.toString} rows=${(batches * rowsPerBatch)->Int.toString}`,
        ~work=async () => {
          for index in 0 to batches - 1 {
            await write(~table, ~itemSchema, ~withDate, ~offset=(index + 1) * rowsPerBatch)
          }
        },
      )

      let loaded = ref(0)
      await measure(
        `read  ${name} rep=${rep->Int.toString} loads=${loadsPerRep->Int.toString}`,
        ~work=async () => {
          for _ in 0 to loadsPerRep - 1 {
            let rows = await sql->BenchAdapter.query(loadAll)
            loaded := rows->Array.length
          }
        },
      )
      log(`read  ${name} rep=${rep->Int.toString} rows_per_load=${loaded.contents->Int.toString}`)
    }
  }

  await exercise("unnest", ~table=unnested, ~withDate=false)
  await exercise("values", ~table=valued, ~withDate=true)

  await BenchAdapter.close(sql)
}

// Where a write's CPU goes before the statement is sent, which is what a second
// storage backend would repeat for the same batch. `lend` is the part of the
// staging that is the arena itself — asking Rust for the buffers and handing
// them back — as against the cells copied into them.
//
// Run by `node bench.mjs splits`. Nothing reaches the server: every batch is
// staged and then abandoned.
let splits = async () => {
  let pgSchema = "bench"
  let sql = PgStorage.makeClient()
  let itemSchema = schemaOf(unnested)
  let data = PgStorage.makeTableBatchSetQuery(~pgSchema, ~table=unnested, ~itemSchema)
  let columns = switch data.binding {
  | Staged({columns}) => columns
  | PerCell => JsError.throwWithMessage("the bench table stages")
  }
  let writeTable =
    sql.client->PgClient.registerWriteTable(
      columns->Array.map(column => column.name),
      columns->Array.map(column => (column.kind :> int)),
    )
  let items =
    batch(~offset=0, ~rows=rowsPerBatch, ~withDate=false)->(Utils.magic: array<'a> => array<unknown>)

  // Warm, so that none of the measured runs pays for the converter's own first
  // pass through the shapes it sees.
  let converted = ref(data.convertOrThrow(items))
  for _ in 0 to 9 {
    converted := data.convertOrThrow(items)
  }

  await measure(`convert rows=${(batches * rowsPerBatch)->Int.toString}`, ~work=async () => {
    for _ in 0 to batches - 1 {
      converted := data.convertOrThrow(items)
    }
  })

  await measure(`lend    rows=${(batches * rowsPerBatch)->Int.toString}`, ~work=async () => {
    for _ in 0 to batches - 1 {
      let arena = sql.client->PgClient.arena
      let stage = arena->Staging.begin(~table=writeTable, ~rows=rowsPerBatch, ~columns)
      stage->Staging.abort
    }
  })

  await measure(`stage   rows=${(batches * rowsPerBatch)->Int.toString}`, ~work=async () => {
    for _ in 0 to batches - 1 {
      let arena = sql.client->PgClient.arena
      let stage = arena->Staging.begin(~table=writeTable, ~rows=rowsPerBatch, ~columns)
      for column in 0 to columns->Array.length - 1 {
        let values = converted.contents->Array.getUnsafe(column)
        for row in 0 to rowsPerBatch - 1 {
          stage->Staging.writeValue(~column, ~row, values->Array.getUnsafe(row))
        }
      }
      stage->Staging.abort
    }
  })

  await BenchAdapter.close(sql)
}
