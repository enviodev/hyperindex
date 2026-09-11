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
  let tableFor = () => {
    let registry = ClickHouse.makeRegistry()
    let table =
      ClickHouse.makeSink(
        ~host="http://127.0.0.1:1",
        ~username="default",
        ~password="",
        ~database="unused",
        ~chainIdMode=Int32,
      )->ClickHouse.entityTable(~registry, ~entityConfig)
    (registry, table)
  }

  it("writes every column of every row shape into its own position", t => {
    let (registry, table) = tableFor()
    let (mock, sink) = MockArena.make(~columns=table.columns)

    let _ = ClickHouse.stageUpdatesOrThrow(
      sink,
      ~registry,
      ~changes,
      ~entityConfig,
      ~scope=Chain(ChainId.fromInt(137)),
    )

    t.expect(mock->MockArena.staged).toEqual([
      {name: "id", values: Texts(["a", "b", "c"]), nulls: [0, 0, 0]},
      {name: "some_int", values: Numbers([5., 0., 7.]), nulls: [0, 1, 0]},
      {name: "opt_float", values: Numbers([1.5, 0., 0.]), nulls: [0, 1, 1]},
      {name: "flag", values: Numbers([1., 0., 0.]), nulls: [0, 1, 0]},
      {name: "at", values: Numbers([1000., 0., 2000.]), nulls: [0, 1, 0]},
      {name: "big", values: Texts(["10", "", "20"]), nulls: [0, 1, 0]},
      {name: "tags", values: Texts([`["x","y"]`, "", "[]"]), nulls: [0, 1, 0]},
      {name: "opt_kind", values: Texts(["A", "", ""]), nulls: [0, 1, 1]},
      {name: "doc", values: Texts([`{"k":1}`, "", "[1]"]), nulls: [0, 1, 0]},
      {name: "owner_id", values: Texts(["alice", "", "carol"]), nulls: [0, 1, 0]},
      {name: "blob", values: Blobs([blobA, emptyBytes, blobC]), nulls: [0, 1, 0]},
      {name: "opt_blob", values: Blobs([optBlobA, emptyBytes, emptyBytes]), nulls: [0, 1, 1]},
      {name: "chunks", values: Texts(["[[1,2],[3]]", "", "[]"]), nulls: [0, 1, 0]},
      {name: "chain_id", values: Numbers([137., 137., 137.]), nulls: [0, 0, 0]},
      {name: "envio_checkpoint_id", values: Unsigned([1n, 2n, 3n]), nulls: [0, 0, 0]},
      {name: "envio_change", values: Texts(["SET", "DELETE", "SET"]), nulls: [0, 0, 0]},
    ])
  })

  // A value bigger than the payload the arena guessed has to reach the column
  // whole: the growth swaps the buffer under the view that is mid-batch. The
  // text is deliberately not ASCII — a string is given room for one byte per
  // UTF-16 unit first, and only the short encode says it needs more.
  it("keeps a value that outgrows the payload it was given", t => {
    let (registry, table) = tableFor()
    let (mock, sink) = MockArena.make(~columns=table.columns)
    let long = "xé😀"->String.repeat(1500)
    let changes = [
      Change.Set({
        entityId: entityId(long),
        checkpointId: 1n,
        entity: entity({
          id: long,
          someInt: 1,
          optFloat: None,
          flag: true,
          at: Date.fromTime(0.),
          big: 1n,
          tags: [],
          optKind: None,
          doc: %raw(`{}`),
          owner_id: "alice",
          blob: Uint8Array.fromArray(Array.make(~length=4000, 7)),
          optBlob: None,
          chunks: [],
        }),
      }),
    ]

    let _ = ClickHouse.stageUpdatesOrThrow(
      sink,
      ~registry,
      ~changes,
      ~entityConfig,
      ~scope=Chain(ChainId.fromInt(137)),
    )

    let staged = mock->MockArena.staged
    t.expect((staged->Array.getUnsafe(0), staged->Array.getUnsafe(10))).toEqual((
      {MockArena.name: "id", values: Texts([long]), nulls: [0]},
      {
        MockArena.name: "blob",
        values: Blobs([Uint8Array.fromArray(Array.make(~length=4000, 7))]),
        nulls: [0],
      },
    ))
  })

  // The arena is Rust memory lent to this side, so a batch that throws mid-fill
  // has to hand it back rather than leave it to a garbage collector that owns
  // none of it.
  it("aborts the stage when a row cannot be converted", t => {
    let (registry, table) = tableFor()
    let (mock, sink) = MockArena.make(~columns=table.columns)
    let changes = [
      Change.Set({
        entityId: entityId("a"),
        checkpointId: 1n,
        entity: entity({
          id: "a",
          someInt: 1,
          optFloat: Some(Float.Constants.nan),
          flag: true,
          at: Date.fromTime(0.),
          big: 1n,
          tags: [],
          optKind: None,
          doc: %raw(`{}`),
          owner_id: "alice",
          blob: emptyBytes,
          optBlob: None,
          chunks: [],
        }),
      }),
    ]

    let failed = try {
      let _ = ClickHouse.stageUpdatesOrThrow(
        sink,
        ~registry,
        ~changes,
        ~entityConfig,
        ~scope=Chain(ChainId.fromInt(137)),
      )
      false
    } catch {
    | _ => true
    }

    t.expect((failed, mock.aborted, mock.committed)).toEqual((true, true, None))
  })
})

// The arena is Rust memory, and the buffers JavaScript writes through are the
// only things keeping a stale view from reaching it. Both entry points check
// what they are handed rather than trusting it, because the alternative is a
// read of memory something can still write and no test that could see it.
describe("Staged buffer checks", () => {
  let staged = () => {
    let sink = ClickHouse.makeSink(
      ~host="http://127.0.0.1:1",
      ~username="default",
      ~password="",
      ~database="unused",
      ~chainIdMode=Int32,
    )
    let registered = sink->ClickHouseSink.registerCheckpointsTable(ClickHouse.checkpointColumnSpecs)
    let begun = sink->ClickHouseSink.beginStage(~table=registered.handle, ~rows=4)
    (sink, registered, begun)
  }

  let messageOf = body =>
    try {
      body()
      "returned without complaint"
    } catch {
    | exn => (exn->Utils.prettifyExn->(Utils.magic: exn => {"message": string}))["message"]
    }

  it("refuses a commit that leaves a buffer attached", t => {
    let (sink, _, begun) = staged()
    t.expect(
      messageOf(() => sink->ClickHouseSink.commitStage(~handle=begun.handle, ~buffers=[])),
    ).toBe("Buffer 0 of the staged batch was not handed back to be detached.")
  })

  it("refuses to grow against a buffer that is not the column's payload", t => {
    let (sink, registered, begun) = staged()
    let column =
      registered.kinds
      ->Array.findIndexOpt(kind => kind->Staging.kindOfOrdinal === Text)
      ->Option.getOrThrow
    t.expect(
      messageOf(
        () =>
          sink
          ->ClickHouseSink.growStage(
            ~handle=begun.handle,
            ~column,
            ~needed=4096,
            ~stale=ArrayBuffer.make(8),
          )
          ->ignore,
      ),
    ).toBe(`The buffer handed to grow is not column ${column->Int.toString}'s payload.`)
  })
})
