// An in-memory mirror of the indexes PostgreSQL holds for the indexer schema.
// Postgres stays authoritative: the registry is loaded from pg_catalog at
// startup/resume and afterwards only grows — optimistically, right after a
// CREATE INDEX we issued succeeds. Only one Indexer instance writes to the
// schema, so no catalog refresh is needed between those two points.

let btree = "btree"

type column = {
  name: string,
  direction: Table.indexFieldDirection,
}

let fromIndexFields = (indexFields: array<Table.compositeIndexField>) =>
  indexFields->Array.map(({fieldName, direction}) => {name: fieldName, direction})

// Identity of an index is table + ordered columns + direction + method. Names
// are deliberately not part of it: the catalog is matched on what the index
// actually covers, not on how it was spelled.
let makeKey = (~tableName, ~columns: array<column>, ~method) =>
  `${tableName}|${method}|${columns
    ->Array.map(({name, direction}) =>
      switch direction {
      | Table.Asc => name
      | Desc => name ++ " DESC"
      }
    )
    ->Array.joinUnsafe(",")}`

type catalogRow = {
  tableName: string,
  indexName: string,
  method: string,
  // 1/0 rather than a bool: postgres.js hands booleans back inconsistently
  // depending on the driver's type resolution, so the query casts it.
  isValid: int,
  // 1 only for an index the indexer could have created: plain btree over plain
  // columns. A unique or partial index carries a definition our key doesn't
  // capture, so it can never be one of ours to rebuild.
  isPlain: int,
  // 1 for an index with a WHERE clause. It only covers rows inside its
  // predicate, so it can't stand in for the unrestricted index a filter needs.
  isPartial: int,
  columns: array<string>,
  // "ASC"/"DESC" per column, in the same order as `columns`.
  directions: array<string>,
}

let catalogRowsSchema = S.array(
  S.object((s): catalogRow => {
    tableName: s.field("tableName", S.string),
    indexName: s.field("indexName", S.string),
    method: s.field("method", S.string),
    isValid: s.field("isValid", S.int),
    isPlain: s.field("isPlain", S.int),
    isPartial: s.field("isPartial", S.int),
    columns: s.field("columns", S.array(S.string)),
    directions: s.field("directions", S.array(S.string)),
  }),
)

// One row per index, with its key columns aggregated in ordinal order.
// INCLUDE columns are excluded (they don't affect what the index can serve),
// and expression columns come back as their printed definition so an
// expression index can never be mistaken for a plain-column one.
let makeCatalogQuery = (~pgSchema) =>
  `SELECT
  t.relname AS "tableName",
  i.relname AS "indexName",
  am.amname AS "method",
  CASE WHEN ix.indisvalid AND ix.indisready THEN 1 ELSE 0 END AS "isValid",
  CASE
    WHEN ix.indisunique OR ix.indpred IS NOT NULL OR ix.indexprs IS NOT NULL THEN 0
    ELSE 1
  END AS "isPlain",
  CASE WHEN ix.indpred IS NOT NULL THEN 1 ELSE 0 END AS "isPartial",
  array_agg(
    CASE WHEN k.attnum = 0
      THEN pg_get_indexdef(ix.indexrelid, k.ord::int, true)
      ELSE a.attname
    END ORDER BY k.ord
  ) AS "columns",
  array_agg(
    CASE WHEN (ix.indoption[k.ord - 1] & 1) = 1 THEN 'DESC' ELSE 'ASC' END ORDER BY k.ord
  ) AS "directions"
FROM pg_index ix
JOIN pg_class i ON i.oid = ix.indexrelid
JOIN pg_class t ON t.oid = ix.indrelid
JOIN pg_namespace n ON n.oid = t.relnamespace
JOIN pg_am am ON am.oid = i.relam
JOIN LATERAL unnest(ix.indkey) WITH ORDINALITY AS k(attnum, ord) ON k.ord <= ix.indnkeyatts
LEFT JOIN pg_attribute a ON a.attrelid = t.oid AND a.attnum = k.attnum
WHERE n.nspname = '${pgSchema}'
GROUP BY t.relname, i.relname, am.amname, ix.indisvalid, ix.indisready,
         ix.indisunique, (ix.indpred IS NOT NULL), (ix.indexprs IS NOT NULL);`

// What we know about an index that came back invalid, enough to decide whether
// rebuilding it would produce the index we actually wanted.
type invalidIndex = {
  key: string,
  isRepairable: bool,
}

type t = {
  keys: Utils.Set.t<string>,
  // Key of the index holding each name. Two descriptions can truncate to one
  // 63-character identifier, and `CREATE INDEX IF NOT EXISTS` matches on name:
  // the second would no-op, and registering its key would leave that column
  // unindexed for the rest of the run.
  keyByName: dict<string>,
  // Every index Postgres reports as invalid, by name. Kept because
  // `CREATE INDEX IF NOT EXISTS` matches on name: with an invalid index already
  // under the name we want, the DDL is a silent no-op and we'd register a key
  // for something the planner refuses to use.
  invalidByName: dict<invalidIndex>,
  // Keyed by index key so identical concurrent requests await one build.
  inflight: dict<promise<unit>>,
  // Tail of the build chain per table, so two different indexes on the same
  // table are built one after the other rather than at once.
  tableQueue: dict<promise<unit>>,
}

let make = () => {
  keys: Utils.Set.make(),
  keyByName: Dict.make(),
  invalidByName: Dict.make(),
  inflight: Dict.make(),
  tableQueue: Dict.make(),
}

let has = (registry, key) => registry.keys->Utils.Set.has(key)

let add = (registry, ~key, ~name) => {
  registry.keys->Utils.Set.add(key)->ignore
  registry.keyByName->Dict.set(name, key)
}

// The key of the index already holding `name`, valid or not.
let getKeyByName = (registry, name) =>
  switch registry.keyByName->Utils.Dict.dangerouslyGetNonOption(name) {
  | Some(key) => Some(key)
  | None =>
    registry.invalidByName
    ->Utils.Dict.dangerouslyGetNonOption(name)
    ->Option.map(invalid => invalid.key)
  }

let size = registry => registry.keys->Utils.Set.size

let toArray = registry => registry.keys->Utils.Set.toArray->Array.toSorted(String.compare)

// A plain CREATE INDEX either commits or leaves nothing behind, so an index can
// only be invalid because something before us left it that way — the startup
// snapshot stays accurate until the next restart.
let getInvalid = (registry, name) => registry.invalidByName->Utils.Dict.dangerouslyGetNonOption(name)

let clearInvalidName = (registry, name) => registry.invalidByName->Utils.Dict.deleteInPlace(name)

// Replaces the whole registry with what the catalog reports. Returns the names
// of indexes Postgres flagged invalid (eg a CREATE INDEX CONCURRENTLY that died
// midway). They stay out of the registry, so the next request that needs one
// repairs it.
let reload = (registry, ~rows: array<catalogRow>) => {
  registry.keys->Utils.Set.clear
  [registry.keyByName, registry.invalidByName->Obj.magic]->Array.forEach(dict =>
    dict->Dict.keysToArray->Array.forEach(name => dict->Utils.Dict.deleteInPlace(name))
  )
  let invalidIndexNames = []
  rows->Array.forEach(row => {
    let key = makeKey(
      ~tableName=row.tableName,
      ~columns=row.columns->Array.mapWithIndex((name, idx) => {
        name,
        direction: switch row.directions->Array.get(idx) {
        | Some("DESC") => Table.Desc
        | _ => Asc
        },
      }),
      ~method=row.method,
    )
    if row.isValid === 0 {
      invalidIndexNames->Array.push(row.indexName)->ignore
      registry.invalidByName->Dict.set(row.indexName, {key, isRepairable: row.isPlain === 1})
    } else if row.isPartial === 1 {
      // It holds the name, so it still blocks a create there, but it can't
      // serve filters outside its predicate — never count it as coverage.
      registry.keyByName->Dict.set(row.indexName, key)
    } else {
      registry->add(~key, ~name=row.indexName)
    }
  })
  invalidIndexNames
}

// Runs `build` unless the index is already registered. The key is added only
// after `build` resolves, so a failed build leaves the registry untouched and
// the next request retries.
let ensure = (registry, ~key, ~name, ~tableName, ~build) =>
  if registry->has(key) {
    Promise.resolve()
  } else {
    switch registry.inflight->Utils.Dict.dangerouslyGetNonOption(key) {
    | Some(promise) => promise
    | None =>
      let tail = switch registry.tableQueue->Utils.Dict.dangerouslyGetNonOption(tableName) {
      | Some(tail) => tail
      | None => Promise.resolve()
      }
      let promise =
        tail
        // The queued build may have been satisfied while waiting behind another
        // one on the same table (eg a finalize pass created it).
        ->Promise.then(() => registry->has(key) ? Promise.resolve() : build())
        ->Promise.thenResolve(() => registry->add(~key, ~name))
      registry.inflight->Dict.set(key, promise)
      registry.tableQueue->Dict.set(tableName, promise->Utils.Promise.silentCatch)
      promise->Promise.finally(() => registry.inflight->Utils.Dict.deleteInPlace(key))
    }
  }

let pgMaxIdentifierLength = 63

// Postgres truncates identifiers past 63 characters on its own. Doing it here
// instead keeps the name we emit, log and read back from the catalog identical
// to the one it stores. Descriptions are ASCII (GraphQL names are), so
// characters and Postgres' byte limit line up.
let truncateIndexName = description =>
  description->String.length > pgMaxIdentifierLength
    ? description->String.slice(~start=0, ~end=pgMaxIdentifierLength)
    : description

// Two distinct descriptions can collapse onto one truncated name — and the
// second `CREATE INDEX IF NOT EXISTS` would then be skipped without a trace,
// leaving the registry claiming an index that doesn't exist.
let validateIndexNamesOrThrow = (descriptions: array<string>) => {
  let byName = Dict.make()
  descriptions->Array.forEach(description => {
    let name = description->truncateIndexName
    switch byName->Utils.Dict.dangerouslyGetNonOption(name) {
    | Some(existing) if existing !== description =>
      JsError.throwWithMessage(
        `Index names "${existing}" and "${description}" both truncate to "${name}" at PostgreSQL's ${pgMaxIdentifierLength->Int.toString}-character identifier limit. Rename a field or an entity so the generated index names stay distinct.`,
      )
    | _ => byName->Dict.set(name, description)
    }
  })
}
