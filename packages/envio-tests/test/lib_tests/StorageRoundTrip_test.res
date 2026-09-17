open Vitest

// Random tables, random rows, written and read back through the storage the
// indexer uses. What this covers that a case written by hand does not is the
// combinations: which of the two insert statements a table's columns select,
// where a value lands in the arena, and what the growth of a column's payload
// does to the rows after it.
//
// A failure names the seed that produced it, and shrinks to the smallest table
// and row count that still fails, so the case can be read.

@val @scope(("process", "env")) external seedEnv: option<string> = "ENVIO_FUZZ_SEED"
@val @scope(("process", "env")) external casesEnv: option<string> = "ENVIO_FUZZ_CASES"

// xorshift32: a generator whose whole state is the seed, so quoting the seed is
// quoting the case.
type random = {mutable state: int}

let make = seed => {state: seed === 0 ? 1 : seed}

%%private(
  let next = random => {
    let x = random.state
    let x = x->Int.bitwiseXor(x->Int.shiftLeft(13))
    let x = x->Int.bitwiseXor(x->Int.shiftRightUnsigned(17))
    let x = x->Int.bitwiseXor(x->Int.shiftLeft(5))
    random.state = x->Int.bitwiseAnd(0x7fffffff)
    random.state
  }
)

let below = (random, bound) => random->next->mod(bound)
let pick = (random, options: array<'a>) =>
  options->Array.getUnsafe(random->below(options->Array.length))
let chance = (random, percent) => random->below(100) < percent

// A column's type, the schema the entity declares for it, and the values worth
// trying — the ones at the edges of what each type can hold, and the ones whose
// text means something to the layer that renders it.
type generator = {
  name: string,
  fieldType: Table.fieldType,
  schema: S.t<unknown>,
  arraySchema: option<S.t<unknown>>,
  values: array<unknown>,
}

let unknown = (value: 'a): unknown => value->(Utils.magic: 'a => unknown)

let longText = String.repeat("long", 200)

let bytes = (values): Uint8Array.t => values->Uint8Array.fromArray

let generators = [
  {
    name: "text",
    fieldType: Table.String,
    schema: S.string->S.toUnknown,
    arraySchema: Some(S.array(S.string)->S.toUnknown),
    values: [
      ""->unknown,
      "plain"->unknown,
      `a,b{"x"}\\`->unknown,
      "NULL"->unknown,
      "{}"->unknown,
      "h\u{e9}llo \u{1F600}"->unknown,
      "line\nbreak\ttab"->unknown,
      "'quoted'"->unknown,
      longText->unknown,
    ],
  },
  {
    name: "flag",
    fieldType: Table.Boolean,
    schema: S.bool->S.toUnknown,
    arraySchema: Some(S.array(S.bool)->S.toUnknown),
    values: [true->unknown, false->unknown],
  },
  {
    name: "int",
    fieldType: Table.Int32,
    schema: S.int->S.toUnknown,
    arraySchema: Some(S.array(S.int)->S.toUnknown),
    values: [0->unknown, 1->unknown, -1->unknown, 2147483647->unknown, -2147483648->unknown],
  },
  {
    name: "float",
    fieldType: Table.Number,
    schema: S.float->S.toUnknown,
    arraySchema: Some(S.array(S.float)->S.toUnknown),
    // No NaN and no infinity: the arena refuses both, on purpose.
    values: [
      0.->unknown,
      1.5->unknown,
      -1.5->unknown,
      1.7976931348623157e308->unknown,
      5e-324->unknown,
    ],
  },
  {
    name: "big",
    fieldType: Table.BigInt({}),
    schema: Utils.BigInt.schema->S.toUnknown,
    arraySchema: Some(S.array(Utils.BigInt.schema)->S.toUnknown),
    values: [
      0n->unknown,
      1n->unknown,
      -1n->unknown,
      9223372036854775807n->unknown,
      -9223372036854775808n->unknown,
      123456789012345678901234567890n->unknown,
      -123456789012345678901234567890n->unknown,
    ],
  },
  {
    name: "dec",
    fieldType: Table.BigDecimal({}),
    schema: BigDecimal.schema->S.toUnknown,
    arraySchema: Some(S.array(BigDecimal.schema)->S.toUnknown),
    values: ["0", "1.5", "-2.25", "1e20", "0.000001"]->Array.map(text =>
      BigDecimal.fromStringUnsafe(text)->unknown
    ),
  },
  {
    name: "at",
    fieldType: Table.Date,
    schema: Utils.Schema.dbDate->S.toUnknown,
    arraySchema: Some(S.array(Utils.Schema.dbDate)->S.toUnknown),
    values: [0., 1234567890123., -86400000., 253402300799000., 1700000000001.]->Array.map(ms =>
      Date.fromTime(ms)->unknown
    ),
  },
  {
    name: "blob",
    fieldType: Table.Bytea,
    schema: Utils.Schema.bytes->S.toUnknown,
    arraySchema: Some(Utils.Schema.bytesArray->S.toUnknown),
    values: [
      bytes([])->unknown,
      bytes([0])->unknown,
      bytes([0xde, 0xad, 0x00, 0xbe])->unknown,
      bytes(Array.make(~length=600, 0x41))->unknown,
    ],
  },
  {
    name: "doc",
    fieldType: Table.Json,
    schema: S.json(~validate=false)->S.toUnknown,
    // No array of documents: each element would have to be rendered as its own
    // text, which only a scalar json column does today.
    arraySchema: None,
    // No bare `null` document: stored, it is indistinguishable from the absence
    // of a value, which is a question about the column rather than about this.
    values: [
      JSON.Encode.int(1)->unknown,
      JSON.Encode.string(`a "quoted", {braced} value`)->unknown,
      JSON.Encode.array([JSON.Encode.int(1), JSON.Encode.bool(true)])->unknown,
      JSON.Encode.object(Dict.fromArray([("k", JSON.Encode.string("v"))]))->unknown,
    ],
  },
]

type column = {
  generator: generator,
  name: string,
  field: Table.fieldOrDerived,
  isArray: bool,
  isNullable: bool,
}

let idField = Table.mkField("id", Table.String, ~fieldSchema=S.string, ~isPrimaryKey=true)

%%private(
  let makeColumn = (random, index) => {
    let generator = random->pick(generators)
    let isArray = generator.arraySchema->Option.isSome && random->chance(25)
    let isNullable = random->chance(35)
    let name = `${generator.name}_${index->Int.toString}`
    let schema = switch (isArray, generator.arraySchema) {
    | (true, Some(arraySchema)) => arraySchema
    | _ => generator.schema
    }
    // What the config builds for an optional field — not `S.null`, whose
    // serializer hands a genuine `null` to the value serializer.
    let schema = isNullable ? Utils.Schema.nullTolerant(schema)->S.toUnknown : schema
    {
      generator,
      name,
      isArray,
      isNullable,
      field: Table.mkField(name, generator.fieldType, ~fieldSchema=schema, ~isArray, ~isNullable),
    }
  }
)

%%private(
  let makeValue = (random, column) =>
    if column.isNullable && random->chance(30) {
      %raw(`null`)
    } else if column.isArray {
      Array.fromInitializer(~length=random->below(4), _ =>
        random->pick(column.generator.values)
      )->unknown
    } else {
      random->pick(column.generator.values)
    }
)

%%private(
  let makeRow = (random, columns, ~index) => {
    let row = Dict.make()
    row->Dict.set("id", `row-${index->Int.toString}`->unknown)
    columns->Array.forEach(column => row->Dict.set(column.name, random->makeValue(column)))
    row
  }
)

// What a row holds, as text that keeps the type apart from the value — so a
// `1.5` that came back as a string rather than a number is a difference.
%%private(
  let shownRow = (columns, row: dict<unknown>) =>
    [("id", PgValue.shown(row->Dict.getUnsafe("id")))]->Array.concat(
      columns->Array.map(column => (column.name, PgValue.shown(row->Dict.getUnsafe(column.name)))),
    )
)

type outcome = Matched({staged: bool}) | Differed({expected: string, actual: string})

// A storage failure wraps the one underneath it, and the one that says what the
// server refused is at the bottom.
%%private(
  let rec because = exn =>
    switch exn->Utils.prettifyExn {
    | Persistence.StorageError({message, reason}) => `${message}: ${because(reason)}`
    | other =>
      other
      ->(Utils.magic: exn => {"message": Nullable.t<string>})
      ->(e => e["message"])
      ->Nullable.toOption
      ->Option.getOr("(no message)")
    }
)

// Writes the rows, reads them back, and says whether what came back is what
// went in. The table is made and dropped per case so nothing carries over.
%%private(
  let attempt = async (sql, ~pgSchema, ~columns, ~rows) => {
    let table = Table.mkTable(
      "fuzzed",
      ~fields=[idField]->Array.concat(columns->Array.map(column => column.field)),
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

    await sql->Sql.batch(`DROP TABLE IF EXISTS "${pgSchema}"."fuzzed";`)
    await sql->Sql.batch(
      PgStorage.makeCreateTableQuery(table, ~pgSchema, ~isNumericArrayAsText=false),
    )

    let batchSet = PgStorage.makeTableBatchSetQuery(~pgSchema, ~table, ~itemSchema)
    let staged = switch batchSet.binding {
    | Staged(_) => true
    | PerCell => false
    }

    await sql->PgStorage.setOrThrow(
      ~items=rows->(Utils.magic: array<dict<unknown>> => array<unknown>),
      ~table,
      ~itemSchema,
      ~pgSchema,
      ~setQueryCache=PgStorage.makeSetQueryCache(),
    )

    let readBack =
      (await sql->Sql.query(PgStorage.makeLoadAllQuery(~pgSchema, ~tableName="fuzzed")))
      ->(Utils.magic: array<unknown> => array<unknown>)
      ->S.parseOrThrow(table->Table.pgRowsSchema)
      ->(Utils.magic: array<unknown> => array<dict<unknown>>)

    let order = (rows: array<dict<unknown>>) =>
      rows->Array.toSorted((a, b) =>
        String.compare(
          a->Dict.getUnsafe("id")->(Utils.magic: unknown => string),
          b->Dict.getUnsafe("id")->(Utils.magic: unknown => string),
        )
      )

    let render = rows =>
      rows->order->Array.map(shownRow(columns, _))->(Utils.magic: 'a => JSON.t)->JSON.stringify
    let expected = render(rows)
    let actual = render(readBack)
    expected === actual ? Matched({staged: staged}) : Differed({expected, actual})
  }
)

// The smallest table and batch that still fails: columns dropped one at a time,
// then rows, keeping whatever still differs.
%%private(
  let shrink = async (sql, ~pgSchema, ~columns, ~rows) => {
    let columns = ref(columns)
    let rows = ref(rows)
    let stillFails = async (~columns, ~rows) =>
      switch await attempt(sql, ~pgSchema, ~columns, ~rows) {
      | Differed(_) => true
      | Matched(_) => false
      | exception _ => true
      }

    let index = ref(0)
    while index.contents < columns.contents->Array.length {
      let without = columns.contents->Array.filterWithIndex((_, at) => at !== index.contents)
      if (
        without->Utils.Array.notEmpty && (await stillFails(~columns=without, ~rows=rows.contents))
      ) {
        columns := without
      } else {
        index := index.contents + 1
      }
    }

    let index = ref(0)
    while index.contents < rows.contents->Array.length {
      let without = rows.contents->Array.filterWithIndex((_, at) => at !== index.contents)
      if (
        without->Utils.Array.notEmpty &&
          (await stillFails(~columns=columns.contents, ~rows=without))
      ) {
        rows := without
      } else {
        index := index.contents + 1
      }
    }
    (columns.contents, rows.contents)
  }
)

let cases = casesEnv->Option.flatMap(text => Int.fromString(text))->Option.getOr(120)
let rootSeed = seedEnv->Option.flatMap(text => Int.fromString(text))->Option.getOr(20260917)

describe("Rows written and read back", () => {
  Async.it(
    "Come back as what went in, for any table the generator builds",
    async t => {
      let sql = PgStorage.makeClient()
      let pgSchema = TestPgSchema.make()
      await sql->Sql.batch(`CREATE SCHEMA "${pgSchema}";`)

      let stagedCases = ref(0)
      let perCellCases = ref(0)
      let failure = ref(None)
      let case = ref(0)

      while failure.contents->Option.isNone && case.contents < cases {
        let seed = rootSeed + case.contents
        let random = make(seed)
        let columns = Array.fromInitializer(~length=1 + random->below(6), index =>
          random->makeColumn(index)
        )
        // Mostly small batches, and now and then one past the point where the
        // statement that binds a cell at a time splits into chunks.
        let rowCount = random->chance(8) ? 500 + random->below(60) : random->below(12)
        let rows = Array.fromInitializer(~length=rowCount, index =>
          random->makeRow(columns, ~index)
        )

        switch await attempt(sql, ~pgSchema, ~columns, ~rows) {
        | Matched({staged}) =>
          staged
            ? stagedCases := stagedCases.contents + 1
            : perCellCases := perCellCases.contents + 1
        | Differed(_) =>
          let (columns, rows) = await shrink(sql, ~pgSchema, ~columns, ~rows)
          let detail = switch await attempt(sql, ~pgSchema, ~columns, ~rows) {
          | Differed({expected, actual}) => `\nwrote ${expected}\nread  ${actual}`
          | _ => ""
          }
          failure :=
            Some(
              `seed ${seed->Int.toString}: ${columns
                ->Array.map(column =>
                  `${column.name}${column.isArray ? "[]" : ""}${column.isNullable ? "?" : ""}`
                )
                ->Array.join(", ")} over ${rows->Array.length->Int.toString} row(s)${detail}`,
            )
        | exception exn =>
          let (columns, rows) = await shrink(sql, ~pgSchema, ~columns, ~rows)
          failure :=
            Some(
              `seed ${seed->Int.toString} threw ${because(exn)}: ${columns
                ->Array.map(column =>
                  `${column.name}${column.isArray ? "[]" : ""}${column.isNullable ? "?" : ""}`
                )
                ->Array.join(", ")} over ${rows->Array.length->Int.toString} row(s)`,
            )
        }
        case := case.contents + 1
      }

      await sql->TestPgSchema.drop(~pgSchema)
      await sql->Sql.close

      // Both statements have to have been exercised, or the run proves half of
      // what it looks like it proves.
      t.expect((
        failure.contents,
        stagedCases.contents > 0,
        perCellCases.contents > 0,
      )).toStrictEqual((None, true, true))
    },
    ~timeout=300_000,
  )
})
