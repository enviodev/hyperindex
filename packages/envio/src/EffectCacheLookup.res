// A cached effect's stored outputs, read straight from storage. For the
// subgraph register pass: it runs at fetch time, outside any handler context,
// so its contract calls can't go through the effect machinery, and after
// `envio start -r` (which keeps the subgraph call caches) it would otherwise ask
// the RPC again for every call it makes.
//
// Only a chain-scoped effect's table that held rows when the run started is
// read: rows this run writes are already in the register pass's own cache.
// The calls of one turn share one storage query.

type batch = {
  effect: Internal.effect,
  table: Table.table,
  keys: array<string>,
  resolvers: array<option<Internal.effectOutput> => unit>,
}

let startupTables: ref<option<Utils.Set.t<string>>> = ref(None)

// Reset between test indexers, which each bring their own storage.
let resetStartupTables = () => startupTables := None

let tablesWithRowsAtStart = (cache: dict<Persistence.effectCacheRecord>) =>
  switch startupTables.contents {
  | Some(tables) => tables
  | None =>
    let tables = Utils.Set.make()
    cache
    ->Dict.valuesToArray
    ->Array.forEach(record =>
      if record.count > 0 {
        tables->Utils.Set.add(record.tableName)->ignore
      }
    )
    startupTables := Some(tables)
    tables
  }

let pending: dict<batch> = Dict.make()

let load = async (storage: Persistence.storage, batch: batch) => {
  let rows =
    (await storage.loadOrThrow(~table=batch.table, ~filter=EntityFilter.byIds(batch.keys)))->(
      Utils.magic: array<unknown> => array<Internal.effectCacheItem>
    )
  let byId = Dict.make()
  rows->Array.forEach(row =>
    switch row.output->S.parseOrThrow(batch.effect.storageMeta.outputSchema) {
    | output => byId->Dict.set(row.id, output)
    | exception _ => ()
    }
  )
  batch.keys->Array.map(key => byId->Utils.Dict.dangerouslyGetNonOption(key))
}

let flush = async (storage: Persistence.storage, tableName) => {
  let batch = pending->Dict.getUnsafe(tableName)
  pending->Utils.Dict.deleteInPlace(tableName)
  let outputs = switch await load(storage, batch) {
  | outputs => outputs
  | exception _ => batch.keys->Array.map(_ => None)
  }
  batch.resolvers->Array.forEachWithIndex((resolve, idx) => resolve(outputs->Array.getUnsafe(idx)))
}

let cached = (effect: Internal.effect, chainId: int, input: Internal.effectInput): promise<
  option<Internal.effectOutput>,
> =>
  switch (
    effect.crossChain,
    EnvioGlobal.value.persistence->(Utils.magic: option<unknown> => option<Persistence.t>),
  ) {
  | (Some(false), Some({storageStatus: Ready({cache}), storage})) =>
    let table = Internal.makeCacheTable(
      ~effectName=effect.name,
      ~scope=Chain(chainId->ChainId.fromInt),
    )
    if cache->tablesWithRowsAtStart->Utils.Set.has(table.tableName) {
      let key =
        input
        ->S.reverseConvertOrThrow(effect.input)
        ->Utils.Hash.makeOrThrow
        ->Utils.Hash.boundCacheKey
      Promise.make((resolve, _) => {
        switch pending->Utils.Dict.dangerouslyGetNonOption(table.tableName) {
        | Some(batch) =>
          batch.keys->Array.push(key)
          batch.resolvers->Array.push(resolve)
        | None =>
          pending->Dict.set(table.tableName, {effect, table, keys: [key], resolvers: [resolve]})
          let _ = setTimeout(() => storage->flush(table.tableName)->ignore, 0)
        }
      })
    } else {
      Promise.resolve(None)
    }
  | _ => Promise.resolve(None)
  }
