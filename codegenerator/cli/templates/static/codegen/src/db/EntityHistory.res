open Table

type historyFieldsGeneral<'a> = {
  chain_id: 'a,
  block_timestamp: 'a,
  block_number: 'a,
  log_index: 'a,
}

type historyFields = historyFieldsGeneral<int>

type historyRow<'entity> = {
  current: historyFields,
  previous: option<historyFields>,
  entityData: 'entity,
}

type previousHistoryFields = historyFieldsGeneral<option<int>>

let previousHistoryFieldsSchema = S.object(s => {
  chain_id: s.field("previous_entity_history_chain_id", S.null(S.int)),
  block_timestamp: s.field("previous_entity_history_block_timestamp", S.null(S.int)),
  block_number: s.field("previous_entity_history_block_number", S.null(S.int)),
  log_index: s.field("previous_entity_history_log_index", S.null(S.int)),
})

let currentHistoryFieldsSchema = S.object(s => {
  chain_id: s.field("entity_history_chain_id", S.int),
  block_timestamp: s.field("entity_history_block_timestamp", S.int),
  block_number: s.field("entity_history_block_number", S.int),
  log_index: s.field("entity_history_log_index", S.int),
})

let makeHistoryRowSchema: S.t<'entity> => S.t<historyRow<'entity>> = entitySchema =>
  S.object(s => {
    {
      "current": s.flatten(currentHistoryFieldsSchema),
      "previous": s.flatten(previousHistoryFieldsSchema),
      "entityData": s.flatten(entitySchema),
    }
  })->S.transform(s => {
    parser: v => {
      current: v["current"],
      previous: switch v["previous"] {
      | {
          chain_id: Some(chain_id),
          block_timestamp: Some(block_timestamp),
          block_number: Some(block_number),
          log_index: Some(log_index),
        } =>
        Some({
          chain_id,
          block_timestamp,
          block_number,
          log_index,
        })
      | {chain_id: None, block_timestamp: None, block_number: None, log_index: None} => None
      | _ => s.fail("Unexpected mix of null and non-null values in previous history fields")
      },
      entityData: v["entityData"],
    },
    serializer: v =>
      {
        "current": v.current,
        "entityData": v.entityData,
        "previous": switch v.previous {
        | Some({chain_id, block_timestamp, block_number, log_index}) => {
            chain_id: Some(chain_id),
            block_timestamp: Some(block_timestamp),
            block_number: Some(block_number),
            log_index: Some(log_index),
          }
        | None => {
            chain_id: None,
            block_timestamp: None,
            block_number: None,
            log_index: None,
          }
        },
      },
  })

type t<'entity> = {
  table: table,
  createInsertFnQuery: string,
  schema: S.t<historyRow<'entity>>,
  insertFn: (Postgres.sql, Js.Json.t) => promise<unit>,
}

let insertRow = (self: t<'entity>, ~sql, ~historyRow: historyRow<'entity>) => {
  let row = historyRow->S.serializeOrRaiseWith(self.schema)
  self.insertFn(sql, row)
}

type entityInternal

external castInternal: t<'entity> => t<entityInternal> = "%identity"

let fromTable = (table: table, ~schema: S.t<'entity>): t<'entity> => {
  let entity_history_block_timestamp = "entity_history_block_timestamp"
  let entity_history_chain_id = "entity_history_chain_id"
  let entity_history_block_number = "entity_history_block_number"
  let entity_history_log_index = "entity_history_log_index"

  //NB: Ordered by hirarchy of event ordering
  let currentChangeFieldNames = [
    entity_history_block_timestamp,
    entity_history_chain_id,
    entity_history_block_number,
    entity_history_log_index,
  ]

  let currentHistoryFields =
    currentChangeFieldNames->Belt.Array.map(fieldName =>
      mkField(fieldName, Integer, ~isPrimaryKey=true)
    )

  let previousChangeFieldNames =
    currentChangeFieldNames->Belt.Array.map(fieldName => "previous_" ++ fieldName)

  let previousHistoryFields =
    previousChangeFieldNames->Belt.Array.map(fieldName =>
      mkField(fieldName, Integer, ~isNullable=true)
    )

  let id = "id"

  let dataFields = table.fields->Belt.Array.keepMap(field =>
    switch field {
    | Field(field) =>
      switch field.fieldName {
      //id is not nullable and should be part of the pk
      | "id" => {...field, fieldName: id, isPrimaryKey: true}->Field->Some
      //db_write_timestamp can be removed for this. TODO: remove this when we depracate
      //automatic db_write_timestamp creation
      | "db_write_timestamp" => None
      | _ =>
        {
          ...field,
          isNullable: true, //All entity fields are nullable in the case
          isIndex: false, //No need to index any additional entity data fields in entity history
        }
        ->Field
        ->Some
      }

    | DerivedFrom(_) => None
    }
  )

  let dataFieldNames = dataFields->Belt.Array.map(field => field->getFieldName)

  let originTableName = table.tableName
  let historyTableName = originTableName ++ "_history"
  //ignore composite indices
  let table = mkTable(
    historyTableName,
    ~fields=Belt.Array.concatMany([currentHistoryFields, previousHistoryFields, dataFields]),
  )

  let insertFnName = `"insert_${table.tableName}"`
  let historyRowArg = "history_row"
  let historyTablePath = `"public"."${historyTableName}"`
  let originTablePath = `"public"."${originTableName}"`

  let previousHistoryFieldsAreNullStr =
    previousChangeFieldNames
    ->Belt.Array.map(fieldName => `${historyRowArg}.${fieldName} IS NULL`)
    ->Js.Array2.joinWith(" OR ")

  let currentChangeFieldNamesCommaSeparated = currentChangeFieldNames->Js.Array2.joinWith(", ")

  let dataFieldNamesDoubleQuoted = dataFieldNames->Belt.Array.map(fieldName => `"${fieldName}"`)
  let dataFieldNamesCommaSeparated = dataFieldNamesDoubleQuoted->Js.Array2.joinWith(", ")

  let allFieldNamesDoubleQuoted =
    Belt.Array.concatMany([
      currentChangeFieldNames,
      previousChangeFieldNames,
      dataFieldNames,
    ])->Belt.Array.map(fieldName => `"${fieldName}"`)

  let createInsertFnQuery = {
    `CREATE OR REPLACE FUNCTION ${insertFnName}(${historyRowArg} ${historyTablePath})
      RETURNS void AS $$
      DECLARE
        v_previous_record RECORD;
        v_origin_record RECORD;
      BEGIN
        -- Check if previous values are not provided
        IF ${previousHistoryFieldsAreNullStr} THEN
          -- Find the most recent record for the same id
          SELECT ${currentChangeFieldNamesCommaSeparated} INTO v_previous_record
          FROM ${historyTablePath}
          WHERE ${id} = ${historyRowArg}.${id}
          ORDER BY ${currentChangeFieldNames
      ->Belt.Array.map(fieldName => fieldName ++ " DESC")
      ->Js.Array2.joinWith(", ")}
          LIMIT 1;

          -- If a previous record exists, use its values
          IF FOUND THEN
            ${Belt.Array.zip(currentChangeFieldNames, previousChangeFieldNames)
      ->Belt.Array.map(((currentFieldName, previousFieldName)) => {
        `${historyRowArg}.${previousFieldName} := v_previous_record.${currentFieldName};`
      })
      ->Js.Array2.joinWith(" ")}
            ElSE
            -- Check if a value for the id exists in the origin table and if so, insert a history row for it.
            SELECT ${dataFieldNamesCommaSeparated} FROM ${originTablePath} WHERE id = ${historyRowArg}.${id} INTO v_origin_record;
            IF FOUND THEN
              INSERT INTO ${historyTablePath} (${currentChangeFieldNamesCommaSeparated}, ${dataFieldNamesCommaSeparated})
              -- SET the current change data fields to 0 since we don't know what they were
              -- and it doesn't matter provided they are less than any new values
              VALUES (${currentChangeFieldNames
      ->Belt.Array.map(_ => "0")
      ->Js.Array2.joinWith(", ")}, ${dataFieldNames
      ->Belt.Array.map(fieldName => `v_origin_record."${fieldName}"`)
      ->Js.Array2.joinWith(", ")});

              ${previousChangeFieldNames
      ->Belt.Array.map(previousFieldName => {
        `${historyRowArg}.${previousFieldName} := 0;`
      })
      ->Js.Array2.joinWith(" ")}
            END IF;
          END IF;
        END IF;

        INSERT INTO ${historyTablePath} (${allFieldNamesDoubleQuoted->Js.Array2.joinWith(", ")})
        VALUES (${allFieldNamesDoubleQuoted
      ->Belt.Array.map(fieldName => `${historyRowArg}.${fieldName}`)
      ->Js.Array2.joinWith(", ")});
      END;
      $$ LANGUAGE plpgsql;
      `
  }

  let insertFnString = `(sql, rowArgs) =>
      sql\`select ${insertFnName}(ROW(${allFieldNamesDoubleQuoted
    ->Belt.Array.map(fieldNameDoubleQuoted => `\${rowArgs[${fieldNameDoubleQuoted}]\}`)
    ->Js.Array2.joinWith(", ")}));\``

  let insertFn: (Postgres.sql, Js.Json.t) => promise<unit> =
    insertFnString->Table.PostgresInterop.eval

  let schema = makeHistoryRowSchema(schema)

  {table, createInsertFnQuery, schema, insertFn}
}
