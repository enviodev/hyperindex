// What `TransactionStore.materialize` and `BlockStore.materialize` lay out: an
// arena with a column per selected field, behind `handle`, and the nested
// fields, which have no column shape, beside it.
type t = {
  handle: int,
  shape: EventStore.arenaShape,
  accessList?: array<Nullable.t<unknown>>,
  authorizationList?: array<Nullable.t<unknown>>,
  accountActivities?: array<Nullable.t<unknown>>,
}

%%private(
  let setNested = (objects: array<dict<unknown>>, ~name, values) =>
    switch values {
    | Some(values) =>
      values->Array.forEachWithIndex((value, row) =>
        switch value {
        | Nullable.Value(value) => objects->Array.getUnsafe(row)->Dict.set(name, value)
        | _ => ()
        }
      )
    | None => ()
    }
)

// A row per requested key, as one object each. A field the row has no value
// for is `undefined`, as an absent field.
let toObjects = (rows: t): array<dict<unknown>> => {
  let {kinds, elementKinds, names, rows: count} = rows.shape
  let objects = EventStore.readHandle(rows.handle, buffers => {
    let columns = Reading.columns(~buffers, ~cursor=ref(0), ~kinds, ~elementKinds, ~rows=count)
    columns->Array.forEach(column =>
      column->Array.forEachWithIndex(
        (value, row) =>
          if value === %raw(`null`) {
            column->Array.setUnsafe(row, %raw(`undefined`))
          },
      )
    )
    columns->Reading.objects(~names, ~rows=count)
  })
  objects->setNested(~name="accessList", rows.accessList)
  objects->setNested(~name="authorizationList", rows.authorizationList)
  objects->setNested(~name="accountActivities", rows.accountActivities)
  objects
}
