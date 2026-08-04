// What the indexer wants an index to be: a table, its ordered key columns with
// their directions, and an access method. That tuple is the index's identity;
// the name is derived from it rather than being part of it, so the catalog can
// always be matched on what an index actually covers.

let btree = "btree"

type column = {
  name: string,
  direction: Table.indexFieldDirection,
}

type t = {
  tableName: string,
  columns: array<column>,
  method: string,
}

let make = (~tableName, ~columns, ~method=btree) => {tableName, columns, method}

let single = (~tableName, ~column) =>
  make(~tableName, ~columns=[{name: column, direction: Table.Asc}])

let fromIndexFields = (~tableName, ~indexFields: array<Table.compositeIndexField>) =>
  make(
    ~tableName,
    ~columns=indexFields->Array.map(({fieldName, direction}) => {name: fieldName, direction}),
  )

let columnKey = ({name, direction}) =>
  switch direction {
  | Table.Asc => name
  | Desc => `${name} DESC`
  }

let key = ({tableName, columns, method}) =>
  `${tableName}|${method}|${columns->Array.map(columnKey)->Array.joinUnsafe(",")}`

let describe = definition =>
  `${definition.tableName}(${definition.columns
    ->Array.map(columnKey)
    ->Array.joinUnsafe(", ")}) using ${definition.method}`

@scope("Math") @val external imul: (int, int) => int = "imul"

// 2166136261 as a signed 32-bit int.
let fnvOffsetBasis = -2128831035
let fnvPrime = 16777619

let fnv1a = (input, ~seed) => {
  let hash = ref(seed)
  for idx in 0 to input->String.length - 1 {
    hash := imul(hash.contents->Int.bitwiseXor(input->String.charCodeAtUnsafe(idx)), fnvPrime)
  }
  hash.contents
}

let hashLength = 10

let toBase36 = (value, ~length) => value->Int.toString(~radix=36)->String.padStart(length, "0")

// 50 bits of the identity, base36-encoded. Two indexes sharing a hash would
// share an identifier, so the width matters: 50 bits is far past the number of
// indexes a schema can hold, while still fitting in 10 characters. The halves
// are encoded separately because combining them would overflow the 32-bit
// integer arithmetic the shifts compile to.
let identityHash = definition => {
  let key = definition->key
  let low = fnv1a(key, ~seed=fnvOffsetBasis)->Int.shiftRightUnsigned(2)
  let high =
    fnv1a(key, ~seed=fnvOffsetBasis->Int.bitwiseXor(0x27d4eb2f))->Int.shiftRightUnsigned(12)
  toBase36(low, ~length=6) ++ toBase36(high, ~length=4)
}

let directionSuffix = (direction: Table.indexFieldDirection) =>
  switch direction {
  | Asc => ""
  | Desc => "_desc"
  }

// `<Entity>_<column>`, with each further column appended in order. Only there so
// a human reading `\d` output can tell what the index is for.
let readablePrefix = ({tableName, columns}) =>
  tableName ++
  "_" ++
  columns
  ->Array.map(({name, direction}) => name ++ directionSuffix(direction))
  ->Array.joinUnsafe("_")

let pgMaxIdentifierLength = 63
let maxPrefixLength = pgMaxIdentifierLength - hashLength - 1

// Postgres truncates identifiers past 63 bytes on its own, and two long field
// names would then collapse onto one name. Truncating only the readable half
// and keeping the hash whole makes every generated name distinct by
// construction. Prefixes are ASCII (GraphQL names are), so characters and
// Postgres' byte limit line up.
let name = definition => {
  let prefix = definition->readablePrefix
  let prefix =
    prefix->String.length > maxPrefixLength
      ? prefix->String.slice(~start=0, ~end=maxPrefixLength)
      : prefix
  `${prefix}_${definition->identityHash}`
}

let directionSql = (direction: Table.indexFieldDirection) =>
  switch direction {
  | Asc => ""
  | Desc => " DESC"
  }

let columnsSql = ({columns}) =>
  columns
  ->Array.map(({name, direction}) => `"${name}"${directionSql(direction)}`)
  ->Array.joinUnsafe(", ")

// Plain DDL, not CONCURRENTLY: it builds from a single table scan instead of
// two, and the SHARE lock it takes blocks writes but not reads, so queries keep
// being served while it runs. The indexer is the only writer, and every caller
// is happy to wait on it.
//
// No `IF NOT EXISTS` either — a skipped create is indistinguishable from a
// successful one, and the whole point of the generated name is that nothing
// else can hold it.
let makeCreateQuery = (definition, ~pgSchema) => {
  let using = definition.method === btree ? "" : ` USING ${definition.method}`
  `CREATE INDEX "${definition->name}" ON "${pgSchema}"."${definition.tableName}"${using}(${definition->columnsSql});`
}

let makeDropQuery = (~pgSchema, ~indexName) => `DROP INDEX IF EXISTS "${pgSchema}"."${indexName}";`
