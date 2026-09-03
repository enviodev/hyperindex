open Vitest

let config = InternalTestIndexer.fromUserApi(
  ~schema=`
enum Kind {
  A
  B
}

type User {
  id: ID!
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
  owner: User!
  blob: Bytes!
  optBlob: Bytes
  chunks: [Bytes!]!
}
`,
  ~configYaml=`
name: clickhouse-staging
bytes_type: uint8array
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
  owner_id: string,
  blob: Uint8Array.t,
  optBlob: option<Uint8Array.t>,
  chunks: array<Uint8Array.t>,
}

let entity = (row: row) => row->(Utils.magic: row => Internal.entity)
let entityId = (id: string) => id->(Utils.magic: string => EntityId.t)

let blobA = Uint8Array.fromArray([1, 2, 3])
let blobC = Uint8Array.fromArray([4, 5])
let optBlobA = Uint8Array.fromArray([9])
let emptyBytes = Uint8Array.fromLength(0)

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
      owner_id: "alice",
      blob: blobA,
      optBlob: Some(optBlobA),
      chunks: [Uint8Array.fromArray([1, 2]), Uint8Array.fromArray([3])],
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
      owner_id: "carol",
      blob: blobC,
      optBlob: None,
      chunks: [],
    }),
  }),
]

describe("ClickHouse staging", () => {
  it("writes every column of every row shape into its own position", t => {
    let registry = ClickHouse.makeRegistry()
    let table =
      ClickHouse.makeSink(
        ~host="http://127.0.0.1:1",
        ~username="default",
        ~password="",
        ~database="unused",
        ~chainIdMode=Int32,
      )->ClickHouse.entityTable(~registry, ~entityConfig)

    let captured = ref(([]: array<ClickHouseSink.columnValuesInput>))
    let sink = {
      "stage": (_table, _rows, columns: array<ClickHouseSink.columnValuesInput>) => {
        captured := columns
        1
      },
    }->(Utils.magic: {..} => ClickHouseSink.t)

    let _ = ClickHouse.stageUpdatesOrThrow(
      sink,
      ~registry,
      ~changes,
      ~entityConfig,
      ~scope=Chain(ChainId.fromInt(137)),
    )

    t.expect((table.columns->Array.map(({name}) => name), captured.contents)).toEqual((
      [
        "id",
        "some_int",
        "opt_float",
        "flag",
        "at",
        "big",
        "tags",
        "opt_kind",
        "doc",
        "owner_id",
        "blob",
        "opt_blob",
        "chunks",
        "chain_id",
        "envio_checkpoint_id",
        "envio_change",
      ],
      [
        {texts: ["a", "b", "c"]},
        {
          numbers: Float64Array.fromArray([5., 0., 7.]),
          nulls: Uint8Array.fromArray([0, 1, 0]),
        },
        {
          numbers: Float64Array.fromArray([1.5, 0., 0.]),
          nulls: Uint8Array.fromArray([0, 1, 1]),
        },
        {
          numbers: Float64Array.fromArray([1., 0., 0.]),
          nulls: Uint8Array.fromArray([0, 1, 0]),
        },
        {
          numbers: Float64Array.fromArray([1000., 0., 2000.]),
          nulls: Uint8Array.fromArray([0, 1, 0]),
        },
        {texts: ["10", "", "20"], nulls: Uint8Array.fromArray([0, 1, 0])},
        {texts: [`["x","y"]`, "", "[]"], nulls: Uint8Array.fromArray([0, 1, 0])},
        {texts: ["A", "", ""], nulls: Uint8Array.fromArray([0, 1, 1])},
        {texts: [`{"k":1}`, "", "[1]"], nulls: Uint8Array.fromArray([0, 1, 0])},
        {texts: ["alice", "", "carol"], nulls: Uint8Array.fromArray([0, 1, 0])},
        {bytes: [blobA, emptyBytes, blobC], nulls: Uint8Array.fromArray([0, 1, 0])},
        {
          bytes: [optBlobA, emptyBytes, emptyBytes],
          nulls: Uint8Array.fromArray([0, 1, 1]),
        },
        {texts: ["[[1,2],[3]]", "", "[]"], nulls: Uint8Array.fromArray([0, 1, 0])},
        {numbers: Float64Array.fromArray([137., 137., 137.])},
        {unsigned64: BigUint64Array.fromArray([1n, 2n, 3n])},
        {texts: ["SET", "DELETE", "SET"]},
      ],
    ))
  })
})
