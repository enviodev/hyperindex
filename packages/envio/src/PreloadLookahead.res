// Preload runs a batch's handlers against the store as it was before the batch,
// so a handler reading an entity an earlier event of the batch creates (a v3
// pool's Mint after its PoolCreated) reads it as absent and makes none of the
// contract calls after that read. The execute pass then asks them one event
// at a time, a round trip each.
//
// So preload reads that find an entity absent are remembered per item, and once
// execute creates that entity, the items that read it are preloaded again, as
// long as they are within `window` items of the one executing. Preload only
// warms the store and the effect cache, and every value it fetches is keyed by
// its full input, so what execute computes is the same with or without it.
//
// Preloading again costs the handler's CPU time once more, and an item whose
// preloads have already spent `maxPreloadMs` (a v3 Mint computing 1.0001^tick
// a step at a time) isn't preloaded again: its calls would land later than the
// CPU it takes away from execute.

type t = {
  items: array<Internal.item>,
  indexOf: Utils.Map.t<Internal.item, int>,
  absentReaders: dict<array<int>>,
  dirty: array<bool>,
  // Milliseconds the item's preload rounds have run for, all runs together.
  preloadMs: array<float>,
  window: int,
  // The last item execute finished; reads and writes at or before it are history.
  mutable executed: int,
}

let active: ref<option<t>> = ref(None)

// Subgraph mappings make their contract calls in the middle of a handler, after
// the reads, so a read that misses is the difference between preloading the
// calls and not. Native handlers are left as they are.
let start = (~items: array<Internal.item>) => {
  let window = Env.subgraphPreloadLookahead
  if Env.subgraphMode.contents && window > 0 {
    let indexOf = Utils.Map.make()
    items->Array.forEachWithIndex((item, idx) => indexOf->Utils.Map.set(item, idx)->ignore)
    active :=
      Some({
        items,
        indexOf,
        absentReaders: Dict.make(),
        dirty: Array.make(~length=items->Array.length, false),
        preloadMs: Array.make(~length=items->Array.length, 0.),
        window,
        executed: -1,
      })
  } else {
    active := None
  }
}

let stop = () => active := None

let maxPreloadMs = 20.

let roundStarted = (~isPreload) =>
  switch active.contents {
  | Some(_) if isPreload => Performance.now()
  | _ => 0.
  }

let roundEnded = (~item: Internal.item, ~startedAt) =>
  if startedAt > 0. {
    switch active.contents {
    | None => ()
    | Some(t) =>
      switch t.indexOf->Utils.Map.get(item) {
      | Some(idx) =>
        t.preloadMs->Array.setUnsafe(
          idx,
          t.preloadMs->Array.getUnsafe(idx) +. startedAt->Performance.secondsSince *. 1000.,
        )
      | None => ()
      }
    }
  }

let entityKey = (~entityName, ~scope: Internal.chainScope, ~entityId) =>
  switch scope {
  | CrossChain => `${entityName}..${entityId}`
  | Chain(chainId) => `${entityName}.${chainId->ChainId.toString}.${entityId}`
  }

let recordAbsent = (~item: Internal.item, ~entityName, ~scope, ~entityId) =>
  switch active.contents {
  | None => ()
  | Some(t) =>
    switch t.indexOf->Utils.Map.get(item) {
    | Some(idx) if idx > t.executed =>
      let key = entityKey(~entityName, ~scope, ~entityId)
      switch t.absentReaders->Utils.Dict.dangerouslyGetNonOption(key) {
      | Some(readers) => readers->Array.push(idx)
      | None => t.absentReaders->Dict.set(key, [idx])
      }
    | _ => ()
    }
  }

let onSet = (~entityName, ~scope, ~entityId) =>
  switch active.contents {
  | None => ()
  | Some(t) =>
    let key = entityKey(~entityName, ~scope, ~entityId)
    switch t.absentReaders->Utils.Dict.dangerouslyGetNonOption(key) {
    | None => ()
    | Some(readers) =>
      t.absentReaders->Utils.Dict.deleteInPlace(key)
      readers->Array.forEach(idx =>
        if idx > t.executed {
          t.dirty->Array.setUnsafe(idx, true)
        }
      )
    }
  }

// Called once execute has finished the item at `index`: the dirty items in the
// window ahead of it are preloaded again against the store as it is now.
let afterItem = (t: t, ~index, ~preload: (Internal.item, int) => unit) => {
  t.executed = index
  let last = Math.Int.min(t.items->Array.length - 1, index + t.window)
  for idx in index + 1 to last {
    if t.dirty->Array.getUnsafe(idx) && t.preloadMs->Array.getUnsafe(idx) < maxPreloadMs {
      t.dirty->Array.setUnsafe(idx, false)
      preload(t.items->Array.getUnsafe(idx), idx)
    }
  }
}
