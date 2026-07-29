// What PostgreSQL actually holds, read straight from pg_catalog and classified
// against what the indexer wanted. Postgres stays authoritative: nothing is
// counted as present until it has been read back from here.

type row = {
  tableName: string,
  indexName: string,
  method: string,
  // 1/0 rather than bools: postgres.js hands booleans back inconsistently
  // depending on the driver's type resolution, so the query casts them.
  isValid: int,
  isUnique: int,
  // An index with a WHERE clause only covers rows inside its predicate, so it
  // can't stand in for the unrestricted index a filter needs.
  isPartial: int,
  isExpression: int,
  // The predicate itself, for the error a partial index under our name earns.
  predicate: option<string>,
  columns: array<string>,
  // "ASC"/"DESC" per column, in the same order as `columns`.
  directions: array<string>,
}

let rowsSchema = S.array(
  S.object((s): row => {
    tableName: s.field("tableName", S.string),
    indexName: s.field("indexName", S.string),
    method: s.field("method", S.string),
    isValid: s.field("isValid", S.int),
    isUnique: s.field("isUnique", S.int),
    isPartial: s.field("isPartial", S.int),
    isExpression: s.field("isExpression", S.int),
    predicate: s.field("predicate", S.null(S.string)),
    columns: s.field("columns", S.array(S.string)),
    directions: s.field("directions", S.array(S.string)),
  }),
)

// One row per index, with its key columns aggregated in ordinal order.
// INCLUDE columns are excluded (they don't affect what the index can serve),
// and expression columns come back as their printed definition so an
// expression index can never be mistaken for a plain-column one.
let makeQuery = (~pgSchema, ~indexName=?) =>
  `SELECT
  t.relname AS "tableName",
  i.relname AS "indexName",
  am.amname AS "method",
  CASE WHEN ix.indisvalid AND ix.indisready THEN 1 ELSE 0 END AS "isValid",
  CASE WHEN ix.indisunique THEN 1 ELSE 0 END AS "isUnique",
  CASE WHEN ix.indpred IS NOT NULL THEN 1 ELSE 0 END AS "isPartial",
  CASE WHEN ix.indexprs IS NOT NULL THEN 1 ELSE 0 END AS "isExpression",
  pg_get_expr(ix.indpred, ix.indrelid, true) AS "predicate",
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
WHERE n.nspname = '${pgSchema}'${switch indexName {
    | Some(indexName) => ` AND i.relname = '${indexName}'`
    | None => ""
    }}
GROUP BY t.relname, i.relname, am.amname, ix.indisvalid, ix.indisready,
         ix.indisunique, ix.indpred, ix.indrelid, (ix.indexprs IS NOT NULL);`

type entry = {
  name: string,
  tableName: string,
  method: string,
  columns: array<IndexDefinition.column>,
  isValid: bool,
  isUnique: bool,
  isPartial: bool,
  isExpression: bool,
  predicate: option<string>,
}

let fromRow = (row: row): entry => {
  name: row.indexName,
  tableName: row.tableName,
  method: row.method,
  columns: row.columns->Array.mapWithIndex((name, idx) => {
    IndexDefinition.name,
    direction: switch row.directions->Array.get(idx) {
    | Some("DESC") => Table.Desc
    | _ => Asc
    },
  }),
  isValid: row.isValid === 1,
  isUnique: row.isUnique === 1,
  isPartial: row.isPartial === 1,
  isExpression: row.isExpression === 1,
  predicate: row.predicate,
}

// Why an index can't serve a request, in the order the checks are worth
// reporting. `None` means it can.
let rejectReason = (entry, definition: IndexDefinition.t) =>
  if entry.tableName !== definition.tableName {
    Some(`it is on table "${entry.tableName}"`)
  } else if !entry.isValid {
    Some("PostgreSQL reports it as invalid or not ready")
  } else if entry.isPartial {
    Some(
      `it is partial (WHERE ${entry.predicate->Option.getOr(
          "...",
        )}), so it only covers part of the table`,
    )
  } else if entry.isExpression {
    Some("it indexes an expression rather than plain columns")
  } else if entry.method !== definition.method {
    Some(`it uses the ${entry.method} access method, not ${definition.method}`)
  } else if (
    definition.columns->Array.length > entry.columns->Array.length ||
      !(
        definition.columns->Array.everyWithIndex((column, idx) =>
          switch entry.columns->Array.get(idx) {
          | Some(actual) => actual.name === column.name && actual.direction === column.direction
          | None => false
          }
        )
      )
  ) {
    Some(
      `it covers (${entry.columns
        ->Array.map(IndexDefinition.columnKey)
        ->Array.joinUnsafe(", ")}) instead of leading with the requested columns`,
    )
  } else {
    None
  }

// A leading-column match is enough: a btree on (a, b) serves everything a btree
// on (a) does. The reverse isn't true, which is why the order matters.
let satisfies = (entry, definition) => entry->rejectReason(definition)->Option.isNone

// The index is byte-for-byte what `definition` asks for, valid or not. Used to
// decide ownership, where a prefix match would be too loose.
let isExactly = (entry, definition: IndexDefinition.t) =>
  entry.tableName === definition.tableName &&
  entry.method === definition.method &&
  !entry.isUnique &&
  !entry.isPartial &&
  !entry.isExpression &&
  entry.columns->Array.length === definition.columns->Array.length &&
  definition.columns->Array.everyWithIndex((column, idx) =>
    switch entry.columns->Array.get(idx) {
    | Some(actual) => actual.name === column.name && actual.direction === column.direction
    | None => false
    }
  )

type t = {byName: dict<entry>}

let make = () => {byName: Dict.make()}

let set = (catalog, entry) => catalog.byName->Dict.set(entry.name, entry)

let fromRows = (~rows) => {
  let catalog = make()
  rows->Array.forEach(row => catalog->set(row->fromRow))
  catalog
}

let getByName = (catalog, name) => catalog.byName->Utils.Dict.dangerouslyGetNonOption(name)

let entries = catalog => catalog.byName->Dict.valuesToArray

let size = catalog => catalog.byName->Dict.keysToArray->Array.length

let find = (catalog, definition) =>
  catalog->entries->Array.find(entry => entry->satisfies(definition))

let invalidNames = catalog =>
  catalog
  ->entries
  ->Array.filterMap(entry => entry.isValid ? None : Some(entry.name))
  ->Array.toSorted(String.compare)
