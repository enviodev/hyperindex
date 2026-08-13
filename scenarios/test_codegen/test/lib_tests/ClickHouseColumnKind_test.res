open Vitest

// `ClickHouseSink.kindOfClickHouseType` casts Rust's `ColumnKind` ordinal
// straight into a ReScript variant, and the column types it is asked about are
// whatever the DDL emits. So two things have to hold: every type envio can
// generate is one Rust knows, and the ordinals still line up. Neither fails
// loudly on its own — a reordered enum silently picks the wrong typed array.

let fieldTypes: array<Table.fieldType> = [
  String,
  Boolean,
  Uint32,
  UInt52,
  UInt64,
  Int32,
  ChainId,
  Number,
  BigInt({}),
  BigInt({precision: 20}),
  BigInt({precision: 40}),
  BigDecimal({}),
  BigDecimal({config: (18, 4)}),
  BigDecimal({config: (40, 4)}),
  Serial,
  BigSerial,
  Json,
  Date,
  Enum({
    config: {
      name: "TestEnum",
      variants: ["A", "B"]->(Utils.magic: array<string> => array<Table.enum>),
      schema: S.string->(Utils.magic: S.t<string> => S.t<Table.enum>),
    },
  }),
]

describe("ClickHouse column kind contract", () => {
  it("Rust resolves a wire kind for every type the DDL emits", t => {
    let unresolved = []
    fieldTypes->Array.forEach(fieldType => {
      ([ChainId.Int32, Int64]: array<ChainId.mode>)->Array.forEach(chainIdMode => {
        [false, true]->Array.forEach(isArray => {
          [false, true]->Array.forEach(isNullable => {
            let chType = ClickHouse.getClickHouseFieldType(
              ~fieldType,
              ~isNullable,
              ~isArray,
              ~chainIdMode,
            )
            try {
              ClickHouseSink.kindOfClickHouseType(chType)->ignore
            } catch {
            | exn =>
              unresolved
              ->Array.push({"chType": chType, "error": exn->Utils.prettifyExn})
              ->ignore
            }
          })
        })
      })
    })
    t.expect(unresolved).toEqual([])
  })

  it("the ordinals ReScript casts match the kinds Rust assigns", t => {
    let kinds =
      [
        "Int32",
        "Float64",
        "UInt64",
        "Int64",
        "String",
        "Decimal(20,0)",
        "Array(String)",
        "Nullable(String)",
        "DateTime64(3, 'UTC')",
      ]->Array.map(ClickHouseSink.kindOfClickHouseType)
    t.expect(kinds).toEqual([
      ClickHouseSink.F64,
      F64,
      U64,
      I64,
      Text,
      Text,
      Text,
      Text,
      F64,
    ])
  })
})
