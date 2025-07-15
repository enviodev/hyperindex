open Table

module RowAction = {
  type t = SET | DELETE
  let variants = [SET, DELETE]
  let name = "ENTITY_HISTORY_ROW_ACTION"
  let schema = S.enum(variants)
}

type historyFieldsGeneral<'a> = {
  chain_id: 'a,
  block_timestamp: 'a,
  block_number: 'a,
  log_index: 'a,
}

type historyFields = historyFieldsGeneral<int>

type entityIdOnly = {id: string}
let entityIdOnlySchema = S.schema(s => {id: s.matches(S.string)})
type entityData<'entity> = Delete(entityIdOnly) | Set('entity)

type historyRow<'entity> = {
  current: historyFields,
  previous: option<historyFields>,
  entityData: entityData<'entity>,
  // In the event of a rollback, some entity updates may have been
  // been affected by a rollback diff. If there was no rollback diff
  // this will always be false.
  // If there was a rollback diff, this will be false in the case of a
  // new entity update (where entity affected is not present in the diff) b
  // but true if the update is related to an entity that is
  // currently present in the diff
  // Optional since it's discarded during parsing/serialization
  containsRollbackDiffChange?: bool,
}

type previousHistoryFields = historyFieldsGeneral<option<int>>

//For flattening the optional previous fields into their own individual nullable fields
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

let makeHistoryRowSchema: S.t<'entity> => S.t<historyRow<'entity>> = entitySchema => {
  //Maps a schema object for the given entity with all fields nullable except for the id field
  //Keeps any original nullable fields
  let nullableEntitySchema: S.t<Js.Dict.t<unknown>> = S.schema(s =>
    switch entitySchema->S.classify {
    | Object({items}) =>
      let nulldict = Js.Dict.empty()
      items->Belt.Array.forEach(({location, schema}) => {
        let nullableFieldSchema = switch (location, schema->S.classify) {
        | ("id", _)
        | (_, Null(_)) => schema //TODO double check this works for array types
        | _ => S.null(schema)->S.toUnknown
        }

        nulldict->Js.Dict.set(location, s.matches(nullableFieldSchema))
      })
      nulldict
    | _ =>
      Js.Exn.raiseError(
        "Failed creating nullableEntitySchema. Expected an object schema for entity",
      )
    }
  )

  let previousWithNullFields = {
    chain_id: None,
    block_timestamp: None,
    block_number: None,
    log_index: None,
  }

  S.object(s => {
    {
      "current": s.flatten(currentHistoryFieldsSchema),
      "previous": s.flatten(previousHistoryFieldsSchema),
      "entityData": s.flatten(nullableEntitySchema),
      "action": s.field("action", RowAction.schema),
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
      entityData: switch v["action"] {
      | SET => v["entityData"]->(Utils.magic: Js.Dict.t<unknown> => 'entity)->Set
      | DELETE =>
        let {id} = v["entityData"]->(Utils.magic: Js.Dict.t<unknown> => entityIdOnly)
        Delete({id: id})
      },
    },
    serializer: v => {
      let (entityData, action) = switch v.entityData {
      | Set(entityData) => (entityData->(Utils.magic: 'entity => Js.Dict.t<unknown>), RowAction.SET)
      | Delete(entityIdOnly) => (
          entityIdOnly->(Utils.magic: entityIdOnly => Js.Dict.t<unknown>),
          DELETE,
        )
      }

      {
        "current": v.current,
        "entityData": entityData,
        "action": action,
        "previous": switch v.previous {
        | Some(historyFields) =>
          historyFields->(Utils.magic: historyFields => previousHistoryFields) //Cast to previousHistoryFields (with "Some" field values)
        | None => previousWithNullFields
        },
      }
    },
  })
}

type t<'entity> = {
  table: table,
  createInsertFnQuery: string,
  schema: S.t<historyRow<'entity>>,
  // Used for parsing
  schemaRows: S.t<array<historyRow<'entity>>>,
  insertFn: (Postgres.sql, Js.Json.t, ~shouldCopyCurrentEntity: bool) => promise<unit>,
}

type entityInternal

external castInternal: t<'entity> => t<entityInternal> = "%identity"
external eval: string => 'a = "eval"

let fromTable = (table: table, ~pgSchema, ~schema: S.t<'entity>): t<'entity> => {
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
      mkField(fieldName, Integer, ~fieldSchema=S.never, ~isPrimaryKey=true)
    )

  let previousChangeFieldNames =
    currentChangeFieldNames->Belt.Array.map(fieldName => "previous_" ++ fieldName)

  let previousHistoryFields =
    previousChangeFieldNames->Belt.Array.map(fieldName =>
      mkField(fieldName, Integer, ~fieldSchema=S.never, ~isNullable=true)
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

  let actionFieldName = "action"

  let actionField = mkField(actionFieldName, Custom(RowAction.name), ~fieldSchema=S.never)

  let serialField = mkField("serial", Serial, ~fieldSchema=S.never, ~isNullable=true, ~isIndex=true)

  let dataFieldNames = dataFields->Belt.Array.map(field => field->getFieldName)

  let originTableName = table.tableName
  let historyTableName = originTableName ++ "_history"
  //ignore composite indices
  let table = mkTable(
    historyTableName,
    ~fields=Belt.Array.concatMany([
      currentHistoryFields,
      previousHistoryFields,
      dataFields,
      [actionField, serialField],
    ]),
  )

  let insertFnName = `"insert_${table.tableName}"`
  let historyRowArg = "history_row"
  let historyTablePath = `"${pgSchema}"."${historyTableName}"`
  let originTablePath = `"${pgSchema}"."${originTableName}"`

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
      [actionFieldName],
    ])->Belt.Array.map(fieldName => `"${fieldName}"`)

  let createInsertFnQuery = {
    `CREATE OR REPLACE FUNCTION ${insertFnName}(${historyRowArg} ${historyTablePath}, should_copy_current_entity BOOLEAN)
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
            ElSIF should_copy_current_entity THEN
            -- Check if a value for the id exists in the origin table and if so, insert a history row for it.
            SELECT ${dataFieldNamesCommaSeparated} FROM ${originTablePath} WHERE id = ${historyRowArg}.${id} INTO v_origin_record;
            IF FOUND THEN
              INSERT INTO ${historyTablePath} (${currentChangeFieldNamesCommaSeparated}, ${dataFieldNamesCommaSeparated}, "${actionFieldName}")
              -- SET the current change data fields to 0 since we don't know what they were
              -- and it doesn't matter provided they are less than any new values
              VALUES (${currentChangeFieldNames
      ->Belt.Array.map(_ => "0")
      ->Js.Array2.joinWith(", ")}, ${dataFieldNames
      ->Belt.Array.map(fieldName => `v_origin_record."${fieldName}"`)
      ->Js.Array2.joinWith(", ")}, 'SET');

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

  let insertFnString = `(sql, rowArgs, shouldCopyCurrentEntity) =>
      sql\`select ${insertFnName}(ROW(${allFieldNamesDoubleQuoted
    ->Belt.Array.map(fieldNameDoubleQuoted => `\${rowArgs[${fieldNameDoubleQuoted}]\}`)
    ->Js.Array2.joinWith(", ")}, NULL),  --NULL argument for SERIAL field
    \${shouldCopyCurrentEntity});\``

  let insertFn: (Postgres.sql, Js.Json.t, ~shouldCopyCurrentEntity: bool) => promise<unit> =
    insertFnString->eval

  let schema = makeHistoryRowSchema(schema)

  {table, createInsertFnQuery, schema, schemaRows: S.array(schema), insertFn}
}
