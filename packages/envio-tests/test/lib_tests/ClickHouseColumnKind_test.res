open Vitest

// The one contract left between the two languages once Rust derives the column
// types: every `Table.fieldType` this side can name has to be one Rust's
// derivation accepts, and the `ColumnKind` ordinals have to keep lining up —
// they cross as bare integers, so a reordered enum in Rust silently makes the
// builder allocate the wrong typed array.
//
// Registration only derives types and never reaches the server, so none of this
// needs a ClickHouse behind it.

let enumConfig =
  Table.makeEnumConfig(~name="TestEnum", ~variants=["A", "B"])->Table.fromGenericEnumConfig

// Built from an exhaustive switch rather than a hand-kept list: a new
// `Table.fieldType` constructor fails to compile here instead of reaching a
// user's deployment as a field type Rust refuses to derive.
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
  | Enum(_) => [Enum({config: enumConfig})]
  | SmallInt
  | Bytea => []
  }

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
    Enum({config: enumConfig}),
  ]
  ->Array.map(samples)
  ->Array.flat

// Every shape a column can be declared in. A nullable list is left out:
// ClickHouse has no `Nullable(Array(...))`, which the next test pins.
let everyColumn =
  fieldTypes->Array.flatMap(fieldType =>
    [(false, false), (true, false), (false, true)]->Array.map(((isNullable, isArray)) =>
      ClickHouse.makeColumnSpec(~name="c", ~fieldType, ~isNullable, ~isArray)
    )
  )

let sink = ClickHouse.makeSink(
  ~host="http://127.0.0.1:1",
  ~username="default",
  ~password="",
  ~database="unused",
  ~chainIdMode=Int32,
)

let register = (columns: array<ClickHouseSink.columnSpec>) =>
  sink->ClickHouseSink.registerCheckpointsTable(
    columns->Array.mapWithIndex((column, index) => {
      ...column,
      name: `c${index->Int.toString}`,
    }),
  )

describe("ClickHouse column type contract", () => {
  it("Rust derives a column type for every field type envio can declare", t => {
    let failed = everyColumn->Array.filterMap(
      column =>
        switch register([column]) {
        | _ => None
        | exception _ => Some(column.fieldType)
        },
    )
    t.expect(failed).toEqual([])
  })

  // A nullable list is a schema every other backend takes, so the refusal has
  // to name the field and the fix rather than surface ClickHouse's own wording
  // from a failed CREATE TABLE.
  it("refuses a nullable list, which ClickHouse has no type for", t => {
    let message = try {
      let _ = register([
        ClickHouse.makeColumnSpec(~name="c", ~fieldType=String, ~isNullable=true, ~isArray=true),
      ])
      "registered without complaint"
    } catch {
    | exn => (exn->Utils.prettifyExn->(Utils.magic: exn => {"message": string}))["message"]
    }
    t.expect(message->String.includes("a nullable list has no ClickHouse type")).toBe(true)
  })

  // Pins all four ordinals: each names the typed array the builder allocates,
  // so a shift in Rust's enum would send a column as the wrong kind.
  it("resolves the wire kind each typed array depends on", t => {
    let {kinds} = register(
      [Table.Int32, UInt64, BigSerial, String]->Array.map(
        fieldType => ClickHouse.makeColumnSpec(~name="c", ~fieldType),
      ),
    )
    t.expect(kinds->Array.map(ClickHouseSink.kindOfOrdinal)).toEqual([
      ClickHouseSink.F64,
      U64,
      I64,
      Text,
    ])
  })

  // A kind added on the Rust side reaches a build of this one that has never
  // heard of it. Naming the mismatch is the whole of what this side can do about
  // it; reading it as the last kind it knows would send the column's values as
  // text and store them as something else.
  it("refuses a wire kind it does not know", t => {
    let message = try {
      let _ = ClickHouseSink.kindOfOrdinal(4)
      "decoded without complaint"
    } catch {
    | exn => (exn->Utils.prettifyExn->(Utils.magic: exn => {"message": string}))["message"]
    }
    t.expect(message).toBe("Unknown ClickHouse column kind 4")
  })
})
