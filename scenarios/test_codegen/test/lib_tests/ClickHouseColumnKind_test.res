open Vitest

// `ClickHouseSink.kindOfField` decides how a column's values cross the napi
// boundary from a `Table.fieldType`; Rust decides how to decode them from the
// type text ClickHouse reports. The two derivations are independent, and a
// mismatch shows up only as a wrongly encoded column, so pin them together over
// every field type the DDL can emit.

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
  it("ReScript picks the wire kind Rust decodes for every field type", t => {
    let mismatches = []
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
            let fromRescript =
              ClickHouseSink.kindOfField(~fieldType, ~isArray, ~chainIdMode)->(
                Utils.magic: ClickHouseSink.kind => int
              )
            let fromRust = Core.getAddon().clickhouseColumnKind(chType)
            if fromRescript !== fromRust {
              mismatches
              ->Array.push({
                "chType": chType,
                "rescriptKind": fromRescript,
                "rustKind": fromRust,
              })
              ->ignore
            }
          })
        })
      })
    })
    t.expect(mismatches).toEqual([])
  })
})
