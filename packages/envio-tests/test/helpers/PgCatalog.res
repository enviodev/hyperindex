type index = {
  tableName: string,
  name: string,
  method: string,
  // An expression column reads as its printed definition.
  columns: array<string>,
  isValid: bool,
  isUnique: bool,
  isPartial: bool,
}

let indexes = (sql, ~pgSchema): promise<array<index>> =>
  sql->Sql.queryForTests(
    `SELECT
  t.relname::text AS "tableName",
  i.relname::text AS "name",
  am.amname::text AS "method",
  ARRAY(
    SELECT COALESCE(a.attname::text, pg_get_indexdef(ix.indexrelid, k.ord::int, true))
    FROM unnest(ix.indkey) WITH ORDINALITY AS k(attnum, ord)
    LEFT JOIN pg_attribute a ON a.attrelid = ix.indrelid AND a.attnum = k.attnum AND k.attnum <> 0
    WHERE k.ord <= ix.indnkeyatts
    ORDER BY k.ord
  ) AS "columns",
  ix.indisvalid AND ix.indisready AS "isValid",
  ix.indisunique AS "isUnique",
  ix.indpred IS NOT NULL AS "isPartial"
FROM pg_index ix
JOIN pg_class i ON i.oid = ix.indexrelid
JOIN pg_class t ON t.oid = ix.indrelid
JOIN pg_namespace n ON n.oid = t.relnamespace
JOIN pg_am am ON am.oid = i.relam
WHERE n.nspname = $1
ORDER BY i.relname;`,
    ~params=[pgSchema->(Utils.magic: string => unknown)],
  )

let leadingWith = async (sql, ~pgSchema, ~tableName, ~columns) =>
  (await sql->indexes(~pgSchema))->Array.filter(index =>
    index.tableName === tableName &&
      columns->Array.everyWithIndex((column, idx) => index.columns->Array.get(idx) === Some(column))
  )
