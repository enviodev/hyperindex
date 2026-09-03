open Vitest

// A batch is staged column by column, in the order the table registered them,
// and each column's values are read straight off the change rather than out
// of a serialized row. The whole staged payload is pinned at once: a column
// reading another's values, or a row shape reading the wrong one, shows up as
// the payload differing rather than as a store holding the wrong data.
//
// Registration never reaches the server, so none of this needs a ClickHouse.

let config = InternalTestIndexer.fromUserApi(
  ~schema=`
enum Kind {
  A
  B
}

type Row {
  id: ID!
  someInt: Int!
  optFloat: Float
  flag: Boolean!
  at: Timestamp!
  big: BigInt!
  tags: [String!]!
  optKind: Kind
  doc: Json!
}
`,
  ~configYaml=`
name: clickhouse-staging
disable_default_cross_chain: true
storage:
  postgres:
    default: true
  clickhouse:
    default: true
    column_name_format: snake_case
chains:
  - id: 1
    start_block: 0
  - id: 137
    start_block: 0
`,
).config

let entityConfig = config.userEntitiesByName->Dict.getUnsafe("Row")

type row = {
  id: string,
  someInt: int,
  optFloat: option<float>,
  flag: bool,
  at: Date.t,
  big: bigint,
  tags: array<string>,
  optKind: option<string>,
  doc: JSON.t,
}

let entity = (row: row) => row->(Utils.magic: row => Internal.entity)
let entityId = (id: string) => id->(Utils.magic: string => EntityId.t)

let changes = [
  Change.Set({
    entityId: entityId("a"),
    checkpointId: 1n,
    entity: entity({
      id: "a",
      someInt: 5,
      optFloat: Some(1.5),
      flag: true,
      at: Date.fromTime(1000.),
      big: 10n,
      tags: ["x", "y"],
      optKind: Some("A"),
      doc: %raw(`{"k": 1}`),
    }),
  }),
  Change.Delete({entityId: entityId("b"), checkpointId: 2n}),
  Change.Set({
    entityId: entityId("c"),
    checkpointId: 3n,
    entity: entity({
      id: "c",
      someInt: 7,
      optFloat: None,
      flag: false,
      at: Date.fromTime(2000.),
      big: 20n,
      tags: [],
      optKind: None,
      doc: %raw(`[1]`),
    }),
  }),
]

let sink = ClickHouse.makeSink(
  ~host="http://127.0.0.1:1",
  ~username="default",
  ~password="",
  ~database="unused",
  ~chainIdMode=Int32,
)

let toArray = (typed: 'typed): array<'a> =>
  typed->(Utils.magic: 'typed => Iterator.t<'a>)->Array.fromIterator

// One plain value per column: its name, what the typed array holds, and the
// null bits when any row set one.
let payload = (builder: ClickHouseSink.builder) => {
  let values: array<unknown> = switch builder.kind {
  | F64 => builder.floats->toArray
  | U64 => builder.unsigned->toArray
  | I64 => builder.signed->toArray
  | Text => builder.texts->(Utils.magic: array<string> => array<unknown>)
  }
  (builder.name, values, builder.nulls->Option.map(toArray))
}

let staged = (~scope) => {
  let registry = ClickHouse.makeRegistry()
  let table = sink->ClickHouse.entityTable(~registry, ~entityConfig)
  let converters = ClickHouse.makeConverters(~entityConfig, ~scope, ~table)
  ClickHouse.fillBuilders(~table, ~converters, ~changes)->Array.map(payload)
}

let u = (value: 'a) => value->(Utils.magic: 'a => unknown)

describe("ClickHouse staging", () => {
  it("writes every column of every row shape into its own position", t => {
    t.expect(staged(~scope=Chain(ChainId.fromInt(137)))).toEqual([
      ("id", [u("a"), u("b"), u("c")], None),
      ("some_int", [u(5.), u(0.), u(7.)], Some([0, 1, 0])),
      ("opt_float", [u(1.5), u(0.), u(0.)], Some([0, 1, 1])),
      ("flag", [u(1.), u(0.), u(0.)], Some([0, 1, 0])),
      ("at", [u(1000.), u(0.), u(2000.)], Some([0, 1, 0])),
      ("big", [u("10"), u(""), u("20")], Some([0, 1, 0])),
      ("tags", [u(`["x","y"]`), u(""), u("[]")], Some([0, 1, 0])),
      ("opt_kind", [u("A"), u(""), u("")], Some([0, 1, 1])),
      ("doc", [u(`{"k":1}`), u(""), u("[1]")], Some([0, 1, 0])),
      ("chain_id", [u(137.), u(137.), u(137.)], None),
      ("envio_checkpoint_id", [u(1n), u(2n), u(3n)], None),
      ("envio_change", [u("SET"), u("DELETE"), u("SET")], None),
    ])
  })

  // The converters are built against the columns the table registered, so a
  // column with no source in the entity is refused up front rather than
  // written from whatever value happens to sit at its index.
  it("refuses a registered column the entity has no value for", t => {
    let table = ClickHouseSink.makeTable(
      ~name="envio_history_Row",
      {handle: 0, names: ["id", "surprise"], kinds: [3, 3], nullable: [false, false]},
    )
    let message = try {
      let _ = ClickHouse.makeConverters(~entityConfig, ~scope=Chain(ChainId.fromInt(137)), ~table)
      "built without complaint"
    } catch {
    | exn => (exn->Utils.prettifyExn->(Utils.magic: exn => {"message": string}))["message"]
    }
    t.expect(message).toBe(
      "ClickHouse table \"envio_history_Row\" registered a column \"surprise\" that entity \"Row\" has no value for",
    )
  })

  it("refuses a table that registered no column for one of the entity's fields", t => {
    let table = ClickHouseSink.makeTable(
      ~name="envio_history_Row",
      {handle: 0, names: ["id"], kinds: [3], nullable: [false]},
    )
    let message = try {
      let _ = ClickHouse.makeConverters(~entityConfig, ~scope=Chain(ChainId.fromInt(137)), ~table)
      "built without complaint"
    } catch {
    | exn => (exn->Utils.prettifyExn->(Utils.magic: exn => {"message": string}))["message"]
    }
    t.expect(message).toBe(
      "ClickHouse table \"envio_history_Row\" registered no column for field \"someInt\" of entity \"Row\"",
    )
  })
})
