// A JavaScript stand-in for the Rust staging arena, laying its buffers out the
// same way `packages/cli/src/columnar` does so a test can read back what
// `Staging` wrote. Nothing is detached here — the point is to look at the bytes
// afterwards.

type staged =
  | Numbers(array<float>)
  | Unsigned(array<bigint>)
  | Signed(array<bigint>)
  | Texts(array<string>)
  | Blobs(array<Uint8Array.t>)

type column = {name: string, values: staged, nulls: array<int>}

type t = {
  columns: array<Staging.column>,
  mutable buffers: array<ArrayBuffer.t>,
  mutable rows: int,
  mutable committed: option<array<column>>,
  mutable aborted: bool,
}

type textDecoder
@new external makeTextDecoder: unit => textDecoder = "TextDecoder"
@send external decode: (textDecoder, Uint8Array.t) => string = "decode"
%%private(let decoder = makeTextDecoder())

@send external setFrom: (Uint8Array.t, Uint8Array.t, int) => unit = "set"

%%private(
  let toArray = (values: TypedArray.t<'a>): array<'a> =>
    values->(Utils.magic: TypedArray.t<'a> => Array.arrayLike<'a>)->Array.fromArrayLike
)

// Deliberately far too small: every batch with a string or a blob in it then
// takes the growth path, which is otherwise only reached by large values.
let initialPayload = 8

%%private(
  let payload = (mock, ~column) => {
    let slot = ref(0)
    let found = ref(-1)
    mock.columns->Array.forEachWithIndex(({kind}, index) => {
      if index === column {
        found := slot.contents
      }
      slot :=
        slot.contents +
        switch kind {
        | Text | Bytes => 3
        | F64 | U64 | I64 => 2
        }
    })
    found.contents
  }
)

%%private(
  let readColumn = (mock, ~column, ~slot) => {
    let {name, kind} = mock.columns->Array.getUnsafe(column)
    let at = offset => mock.buffers->Array.getUnsafe(slot + offset)
    let (values, nullsBuffer) = switch kind {
    | F64 => (Numbers(Float64Array.fromBuffer(at(0))->toArray), at(1))
    | U64 => (Unsigned(BigUint64Array.fromBuffer(at(0))->toArray), at(1))
    | I64 => (Signed(BigInt64Array.fromBuffer(at(0))->toArray), at(1))
    | Text | Bytes =>
      let data = Uint8Array.fromBuffer(at(0))
      let ends = Uint32Array.fromBuffer(at(1))
      let slices = Array.fromInitializer(~length=mock.rows, row => {
        let start = row === 0 ? 0 : ends->TypedArray.get(row - 1)->Option.getOrThrow
        let end = ends->TypedArray.get(row)->Option.getOrThrow
        data->TypedArray.slice(~start, ~end)
      })
      (
        kind === Text ? Texts(slices->Array.map(slice => decoder->decode(slice))) : Blobs(slices),
        at(2),
      )
    }
    {name, values, nulls: Uint8Array.fromBuffer(nullsBuffer)->toArray}
  }
)

let make = (~columns: array<Staging.column>) => {
  let mock = {columns, buffers: [], rows: 0, committed: None, aborted: false}
  let arena: Staging.arena = {
    beginStage: (~table as _, ~rows) => {
      mock.rows = rows
      mock.buffers = []
      columns->Array.forEach(({kind}) => {
        switch kind {
        | F64 | U64 | I64 => mock.buffers->Array.push(ArrayBuffer.make(rows * 8))
        | Text | Bytes =>
          mock.buffers->Array.push(ArrayBuffer.make(initialPayload))
          mock.buffers->Array.push(ArrayBuffer.make(rows * 4))
        }
        mock.buffers->Array.push(ArrayBuffer.make(rows))
      })
      {handle: 1, buffers: mock.buffers}
    },
    growStage: (~handle as _, ~column, ~needed, ~stale) => {
      let capacity = ref(stale->ArrayBuffer.byteLength)
      while capacity.contents < needed {
        capacity := capacity.contents * 2
      }
      let fresh = ArrayBuffer.make(capacity.contents)
      Uint8Array.fromBuffer(fresh)->setFrom(Uint8Array.fromBuffer(stale), 0)
      mock.buffers->Array.setUnsafe(mock->payload(~column), fresh)
      fresh
    },
    commitStage: (~handle as _, ~buffers) => {
      mock.buffers = buffers
      let staged = []
      let slot = ref(0)
      columns->Array.forEachWithIndex(({kind}, column) => {
        staged->Array.push(mock->readColumn(~column, ~slot=slot.contents))
        slot :=
          slot.contents +
          switch kind {
          | Text | Bytes => 3
          | F64 | U64 | I64 => 2
          }
      })
      mock.committed = Some(staged)
    },
    abortStage: (~handle as _, ~buffers as _) => mock.aborted = true,
  }
  (mock, arena->(Utils.magic: Staging.arena => ClickHouseSink.t))
}

let staged = mock =>
  switch mock.committed {
  | Some(staged) => staged
  | None => JsError.throwWithMessage("the stage was never committed")
  }
