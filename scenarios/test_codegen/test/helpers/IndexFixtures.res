// A catalog row as pg_catalog would report it, defaulting to the shape of an
// index the indexer itself would have built.
let makeRow = (
  ~tableName,
  ~indexName,
  ~columns,
  ~directions=?,
  ~method="btree",
  ~isValid=1,
  ~isUnique=0,
  ~isPartial=0,
  ~isExpression=0,
  ~predicate=?,
): IndexCatalog.row => {
  tableName,
  indexName,
  method,
  isValid,
  isUnique,
  isPartial,
  isExpression,
  predicate,
  columns,
  directions: switch directions {
  | Some(directions) => directions
  | None => columns->Array.map(_ => "ASC")
  },
}

let makeEntry = row => row->IndexCatalog.fromRow
