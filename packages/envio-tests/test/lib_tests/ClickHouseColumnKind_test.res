open Vitest

// Registering a table is where Rust parses the types the DDL emits, so it is
// the seam between two closed sets: what `getClickHouseFieldType` can write and
// what the encoder can hold. Two things have to keep holding — every type envio
// can generate is one Rust knows, and the `ColumnKind` ordinals still line up,
// since a reordered enum silently picks the wrong typed array.

// Built from an exhaustive switch rather than a hand-kept list: a new
// `Table.fieldType` constructor fails to compile here instead of reaching a
// user's deployment as an unparseable column type.
let samples = (fieldType: Table.fieldType): array<Table.fieldType> =>
  switch fieldType {
  | String
  | Boolean
  | Uint32
  | UInt52
  | UInt64
  | Int32
  | ChainId
  | Number
  | Serial
  | BigSerial
  | Json
  | Date => [fieldType]
  // The bounded forms map to Decimal and the rest fall back to String, so each
  // branch needs covering on both sides of its precision limit.
  | BigInt(_) => [BigInt({}), BigInt({precision: 20}), BigInt({precision: 40})]
  | BigDecimal(_) => [BigDecimal({}), BigDecimal({config: (18, 4)}), BigDecimal({config: (40, 4)})]
  | Enum(_) => [
      Enum({
        config: {
          name: "TestEnum",
          variants: ["A", "B"]->(Utils.magic: array<string> => array<Table.enum>),
          schema: S.string->(Utils.magic: S.t<string> => S.t<Table.enum>),
        },
      }),
    ]
  }

let enumSample = Table.Enum({
  config: {
    name: "TestEnum",
    variants: ["A", "B"]->(Utils.magic: array<string> => array<Table.enum>),
    schema: S.string->(Utils.magic: S.t<string> => S.t<Table.enum>),
  },
})

let fieldTypes =
  [
    Table.String,
    Boolean,
    Uint32,
    UInt52,
    UInt64,
    Int32,
    ChainId,
    Number,
    BigInt({}),
    BigDecimal({}),
    Serial,
    BigSerial,
    Json,
    Date,
    enumSample,
  ]
  ->Array.map(samples)
  ->Array.flat

// Every shape the DDL can wrap a base type in.
let everyEmittedType = fieldTypes->Array.flatMap(fieldType =>
  [(false, false), (true, false), (false, true)]->Array.map(((isNullable, isArray)) =>
    ClickHouse.getClickHouseFieldType(~fieldType, ~isNullable, ~isArray)
  )
)

// Registration parses the types it is given and never reaches the server, so
// none of this needs a ClickHouse behind it.
let sink = ClickHouse.makeSink(
  ~host="http://127.0.0.1:1",
  ~username="default",
  ~password="",
  ~database="unused",
)

let register = chTypes =>
  sink->ClickHouseSink.registerTableOrThrow(
    ~table="contract",
    ~columns=chTypes->Array.mapWithIndex((chType, index) => {
      ClickHouseSink.name: `c${index->Int.toString}`,
      chType,
    }),
  )

describe("ClickHouse column type contract", () => {
  it("Rust parses every type the DDL emits", t => {
    let failed = everyEmittedType->Array.filter(chType =>
      switch register([chType]) {
      | _ => false
      | exception _ => true
      }
    )
    t.expect(failed).toEqual([])
  })

  // Pins all four ordinals: each names the typed array the builder allocates,
  // so a shift in Rust's enum would send a column as the wrong kind.
  it("resolves the wire kind each typed array depends on", t => {
    let table = register(["Int32", "UInt64", "Int64", "String"])
    t.expect(table.columns->Array.map(({kind}) => kind)).toEqual([
      ClickHouseSink.F64,
      U64,
      I64,
      Text,
    ])
  })
})
