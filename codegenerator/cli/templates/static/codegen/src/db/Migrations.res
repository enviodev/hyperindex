let sql = DbFunctions.sql
let unsafe = Postgres.unsafe

let creatTableIfNotExists = (sql, table) => {
  open Belt
  let fieldsMapped =
    table
    ->Table.getFields
    ->Array.map(field => {
      let {fieldType, isNullable, isArray, defaultValue} = field
      let fieldName = field->Table.getDbFieldName

      {
        `"${fieldName}" ${(fieldType :> string)}${isArray ? "[]" : ""}${switch defaultValue {
          | Some(defaultValue) => ` DEFAULT ${defaultValue}`
          | None => isNullable ? `` : ` NOT NULL`
          }}`
      }
    })
    ->Js.Array2.joinWith(", ")

  let primaryKeyFieldNames = table->Table.getPrimaryKeyFieldNames
  let primaryKey =
    primaryKeyFieldNames
    ->Array.map(field => `"${field}"`)
    ->Js.Array2.joinWith(", ")

  let query = `
    CREATE TABLE IF NOT EXISTS "public"."${table.tableName}"(${fieldsMapped}${primaryKeyFieldNames->Array.length > 0
      ? `, PRIMARY KEY(${primaryKey})`
      : ""});`

  sql->unsafe(query)
}

let makeCreateIndexQuery = (~tableName, ~indexFields) => {
  let indexName = tableName ++ "_" ++ indexFields->Js.Array2.joinWith("_")
  let index = indexFields->Belt.Array.map(idx => `"${idx}"`)->Js.Array2.joinWith(", ")
  `CREATE INDEX IF NOT EXISTS "${indexName}" ON "public"."${tableName}"(${index}); `
}

let createTableIndices = (sql, table: Table.table) => {
  open Belt
  let tableName = table.tableName
  let createIndex = indexField => makeCreateIndexQuery(~tableName, ~indexFields=[indexField])
  let createCompositeIndex = indexFields => {
    makeCreateIndexQuery(~tableName, ~indexFields)
  }

  let singleIndices = table->Table.getSingleIndices
  let compositeIndices = table->Table.getCompositeIndices

  let query =
    singleIndices->Array.map(createIndex)->Js.Array2.joinWith("\n") ++
      compositeIndices->Array.map(createCompositeIndex)->Js.Array2.joinWith("\n")

  sql->unsafe(query)
}

let createDerivedFromDbIndex = (~derivedFromField: Table.derivedFromField, ~schema: Schema.t) => {
  let indexField = schema->Schema.getDerivedFromFieldName(derivedFromField)->Utils.unwrapResultExn
  let query = makeCreateIndexQuery(
    ~tableName=derivedFromField.derivedFromEntity,
    ~indexFields=[indexField],
  )
  sql->unsafe(query)
}

let createEnumIfNotExists = (sql, enum: Enums.enumType<_>) => {
  open Belt
  let {variants, name} = enum
  let mappedVariants = variants->Array.map(v => `'${v->Utils.magic}'`)->Js.Array2.joinWith(", ")
  let query = `
      DO $$ BEGIN
      IF NOT EXISTS(SELECT 1 FROM pg_type WHERE typname = '${name->Js.String2.toLowerCase}') THEN
        CREATE TYPE ${name} AS ENUM(${mappedVariants});
        END IF;
      END $$; `

  sql->unsafe(query)
}

module EntityHistory = {
  let createEntityHistoryTableFunctions: unit => promise<unit> = async () => {
    let _ = await sql->unsafe(`
      CREATE OR REPLACE FUNCTION safe_record_to_jsonb(input_record RECORD)
      RETURNS JSONB
      LANGUAGE plpgsql
      AS $$
      DECLARE
          json_result JSONB;
      BEGIN
          -- Convert the record into a JSONB object, iterate over each field
          SELECT jsonb_object_agg(d.key, 
                                  CASE 
                                      WHEN jsonb_typeof(d.value) = 'array' THEN 
                                          CASE 
                                              WHEN jsonb_array_length(d.value) = 0 THEN '[]'::JSONB  -- Return empty array
                                              ELSE 
                                                  (
                                                      SELECT jsonb_agg(
                                                          CASE 
                                                              WHEN jsonb_typeof(elem) = 'number' THEN to_jsonb(elem::TEXT)
                                                              ELSE elem
                                                          END
                                                      )
                                                      FROM jsonb_array_elements(d.value) AS elem
                                                  )
                                          END
                                      WHEN jsonb_typeof(d.value) = 'number' THEN to_jsonb(d.value::TEXT)
                                      ELSE d.value
                                  END)
          INTO json_result
          FROM jsonb_each(to_jsonb(input_record)) AS d;

          RETURN json_result;
      END;
      $$;
    `)

    let _ = await sql->unsafe(`
      CREATE OR REPLACE FUNCTION copy_table_to_entity_history(source_table_name TEXT)
      RETURNS VOID AS $$
      DECLARE
          row RECORD;
          sql_query TEXT;
      BEGIN
          -- Dynamically construct the query to select all rows from the given source table
          sql_query := 'SELECT * FROM ' || quote_ident(source_table_name);
          
          -- Loop through each row in the dynamically selected table
          FOR row IN EXECUTE sql_query LOOP
              -- Insert the serialized JSON and other provided values into the entity_history table
              INSERT INTO entity_history (
                entity_id,
                block_timestamp,
                chain_id,
                block_number,
                log_index,
                entity_type,
                params
              )
              VALUES (
                row.id,
                0,
                0,
                0,
                0,
                source_table_name::entity_type,
                safe_record_to_jsonb(row)
              );
          END LOOP;
      END;
      $$ LANGUAGE plpgsql;
    `)

    // Create a function for inserting entities into the db.
    let _ = await sql->unsafe(`
      CREATE OR REPLACE FUNCTION insert_entity_history(
          p_block_timestamp INTEGER,
          p_chain_id INTEGER,
          p_block_number INTEGER,
          p_log_index INTEGER,
          p_params JSONB,
          p_entity_type ENTITY_TYPE,
          p_entity_id TEXT,
          p_previous_block_timestamp INTEGER DEFAULT NULL,
          p_previous_chain_id INTEGER DEFAULT NULL,
          p_previous_block_number INTEGER DEFAULT NULL,
          p_previous_log_index INTEGER DEFAULT NULL
      )
      RETURNS void AS $$
      DECLARE
          v_previous_record RECORD;
      BEGIN
          -- Check if previous values are not provided
          IF p_previous_block_timestamp IS NULL OR p_previous_chain_id IS NULL OR p_previous_block_number IS NULL OR p_previous_log_index IS NULL THEN
              -- Find the most recent record for the same entity_type and entity_id
              SELECT block_timestamp, chain_id, block_number, log_index INTO v_previous_record
              FROM entity_history
              WHERE entity_type = p_entity_type AND entity_id = p_entity_id
              ORDER BY block_timestamp DESC
              LIMIT 1;
              
              -- If a previous record exists, use its values
              IF FOUND THEN
                  p_previous_block_timestamp := v_previous_record.block_timestamp;
                  p_previous_chain_id := v_previous_record.chain_id;
                  p_previous_block_number := v_previous_record.block_number;
                  p_previous_log_index := v_previous_record.log_index;
              END IF;
          END IF;
          
          -- Insert the new record with either provided or looked-up previous values
          INSERT INTO entity_history (block_timestamp, chain_id, block_number, log_index, previous_block_timestamp, previous_chain_id, previous_block_number, previous_log_index, params, entity_type, entity_id)
          VALUES (p_block_timestamp, p_chain_id, p_block_number, p_log_index, p_previous_block_timestamp, p_previous_chain_id, p_previous_block_number, p_previous_log_index, p_params, p_entity_type, p_entity_id);
      END;
      $$ LANGUAGE plpgsql;
    `)
  }

  // NULL for an `entity_id` means that the entity was deleted.
  let createEntityHistoryPostgresFunction: unit => promise<unit> = async () => {
    let _ = await sql->unsafe(`
    CREATE OR REPLACE FUNCTION lte_entity_history(
        block_timestamp integer,
        chain_id integer,
        block_number integer,
        log_index integer,
        compare_timestamp integer,
        compare_chain_id integer,
        compare_block integer,
        compare_log_index integer
    )
    RETURNS boolean AS $ltelogic$
    BEGIN
        RETURN (
            block_timestamp < compare_timestamp
            OR (
                block_timestamp = compare_timestamp
                AND (
                    chain_id < compare_chain_id
                    OR (
                        chain_id = compare_chain_id
                        AND (
                            block_number < compare_block
                            OR (
                                block_number = compare_block
                                AND log_index <= compare_log_index
                            )
                        )
                    )
                )
            )
        );
    END;
    $ltelogic$ LANGUAGE plpgsql STABLE;
      `)

    // Very similar to lte function but the final comparison on logIndex is a strict lt.
    let _ = await sql->unsafe(`
    CREATE OR REPLACE FUNCTION lt_entity_history(
        block_timestamp integer,
        chain_id integer,
        block_number integer,
        log_index integer,
        compare_timestamp integer,
        compare_chain_id integer,
        compare_block integer,
        compare_log_index integer
    )
    RETURNS boolean AS $ltlogic$
    BEGIN
        RETURN (
            block_timestamp < compare_timestamp
            OR (
                block_timestamp = compare_timestamp
                AND (
                    chain_id < compare_chain_id
                    OR (
                        chain_id = compare_chain_id
                        AND (
                            block_number < compare_block
                            OR (
                                block_number = compare_block
                                AND log_index < compare_log_index
                            )
                        )
                    )
                )
            )
        );
    END;
    $ltlogic$ LANGUAGE plpgsql STABLE;
      `)

    let _ = await sql->unsafe(`
      CREATE OR REPLACE FUNCTION get_entity_history_filter(
          start_timestamp integer,
          start_chain_id integer,
          start_block integer,
          start_log_index integer,
          end_timestamp integer,
          end_chain_id integer,
          end_block integer,
          end_log_index integer
      )
      RETURNS SETOF entity_history_filter AS $$
      BEGIN
          RETURN QUERY
          SELECT
              DISTINCT ON (coalesce(old.entity_id, new.entity_id))
              coalesce(old.entity_id, new.entity_id) as entity_id,
              new.chain_id as chain_id,
              coalesce(old.params, 'null') as old_val,
              coalesce(new.params, 'null') as new_val,
              new.block_number as block_number,
              old.block_number as previous_block_number,
              new.log_index as log_index,
              old.log_index as previous_log_index,
              new.entity_type as entity_type
          FROM
              entity_history old
              INNER JOIN entity_history next ON
              old.entity_id = next.entity_id
              AND old.entity_type = next.entity_type
              AND old.block_number = next.previous_block_number
              AND old.log_index = next.previous_log_index
            -- start <= next -- QUESTION: Should this be <?
              AND lt_entity_history(
                  start_timestamp,
                  start_chain_id,
                  start_block,
                  start_log_index,
                  next.block_timestamp,
                  next.chain_id,
                  next.block_number,
                  next.log_index
              )
            -- old < start -- QUESTION: Should this be <=?
              AND lt_entity_history(
                  old.block_timestamp,
                  old.chain_id,
                  old.block_number,
                  old.log_index,
                  start_timestamp,
                  start_chain_id,
                  start_block,
                  start_log_index
              )
            -- next <= end
              AND lte_entity_history(
                  next.block_timestamp,
                  next.chain_id,
                  next.block_number,
                  next.log_index,
                  end_timestamp,
                  end_chain_id,
                  end_block,
                  end_log_index
              )
              FULL OUTER JOIN entity_history new ON old.entity_id = new.entity_id
              AND new.entity_type = old.entity_type -- Assuming you want to check if entity types are the same
              AND lte_entity_history(
                  start_timestamp,
                  start_chain_id,
                  start_block,
                  start_log_index,
                  new.block_timestamp,
                  new.chain_id,
                  new.block_number,
                  new.log_index
              )
            -- new <= end
              AND lte_entity_history(
                  new.previous_block_timestamp,
                  new.previous_chain_id,
                  new.previous_block_number,
                  new.previous_log_index,
                  end_timestamp,
                  end_chain_id,
                  end_block,
                  end_log_index
              )
          WHERE
              lte_entity_history(
                  new.block_timestamp,
                  new.chain_id,
                  new.block_number,
                  new.log_index,
                  end_timestamp,
                  end_chain_id,
                  end_block,
                  end_log_index
              )
              AND lte_entity_history(
                  coalesce(old.block_timestamp, 0),
                  old.chain_id,
                  old.block_number,
                  old.log_index,
                  start_timestamp,
                  start_chain_id,
                  start_block,
                  start_log_index
              )
              AND lte_entity_history(
                  start_timestamp,
                  start_chain_id,
                  start_block,
                  start_log_index,
                  coalesce(new.block_timestamp, start_timestamp + 1),
                  new.chain_id,
                  new.block_number,
                  new.log_index
              )
          ORDER BY
              coalesce(old.entity_id, new.entity_id),
              new.block_number DESC,
              new.log_index DESC;
      END;
      $$ LANGUAGE plpgsql STABLE;
`)
  }
}

let deleteAllTables: unit => promise<unit> = async () => {
  // await EntityHistory.dropEntityHistoryTable()

  Logging.trace("Dropping all tables")
  // NOTE: we can refine the `IF EXISTS` part because this now prints to the terminal if the table doesn't exist (which isn't nice for the developer).

  @warning("-21")
  await (
    %raw(
      "sql.unsafe`DROP SCHEMA public CASCADE;CREATE SCHEMA public;GRANT ALL ON SCHEMA public TO postgres;GRANT ALL ON SCHEMA public TO public;`"
    )
  )
}

type t
@module external process: t = "process"

type exitCode = | @as(0) Success | @as(1) Failure
@send external exit: (t, exitCode) => unit = "exit"

let awaitEach = Utils.Array.awaitEach

// TODO: all the migration steps should run as a single transaction
let runUpMigrations = async (~shouldExit) => {
  let exitCode = ref(Success)
  let logger = Logging.createChild(~params={"context": "Running DB Migrations"})

  let handleFailure = async (res, ~msg) =>
    switch await res {
    | exception exn =>
      exitCode := Failure
      exn->ErrorHandling.make(~msg, ~logger)->ErrorHandling.log
    | _ => ()
    }

  //Add all enums
  await Enums.allEnums->awaitEach(enum => {
    let module(EnumMod) = enum
    createEnumIfNotExists(DbFunctions.sql, EnumMod.enum)->handleFailure(
      ~msg=`EE800: Error creating ${EnumMod.enum.name} enum`,
    )
  })

  //Create all tables with indices
  await [TablesStatic.allTables, Entities.allTables]
  ->Belt.Array.concatMany
  ->awaitEach(async table => {
    await creatTableIfNotExists(DbFunctions.sql, table)->handleFailure(
      ~msg=`EE800: Error creating ${table.tableName} table`,
    )
    await createTableIndices(DbFunctions.sql, table)->handleFailure(
      ~msg=`EE800: Error creating ${table.tableName} indices`,
    )
  })

  //Create extra entity history tables
  await EntityHistory.createEntityHistoryTableFunctions()->handleFailure(
    ~msg=`EE800: Error creating entity history table`,
  )

  await EntityHistory.createEntityHistoryPostgresFunction()->handleFailure(
    ~msg=`EE800: Error creating entity history db function table`,
  )

  //Create all derivedFromField indices (must be done after all tables are created)
  await [Entities.allTables]
  ->Belt.Array.concatMany
  ->awaitEach(async table => {
    await table
    ->Table.getDerivedFromFields
    ->awaitEach(derivedFromField => {
      createDerivedFromDbIndex(~derivedFromField, ~schema=Entities.schema)->handleFailure(
        ~msg=`Error creating derivedFrom index of "${derivedFromField.fieldName}" in entity "${table.tableName}"`,
      )
    })
  })

  await TrackTables.trackAllTables()->Promise.catch(err => {
    Logging.errorWithExn(err, `EE803: Error tracking tables`)->Promise.resolve
  })

  if shouldExit {
    process->exit(exitCode.contents)
  }
  exitCode.contents
}

let runDownMigrations = async (~shouldExit) => {
  let exitCode = ref(Success)
  await deleteAllTables()->Promise.catch(err => {
    exitCode := Failure
    err
    ->ErrorHandling.make(~msg="EE804: Error dropping entity tables")
    ->ErrorHandling.log
    Promise.resolve()
  })
  if shouldExit {
    process->exit(exitCode.contents)
  }
  exitCode.contents
}

let setupDb = async () => {
  Logging.info("Provisioning Database")
  // TODO: we should make a hash of the schema file (that gets stored in the DB) and either drop the tables and create new ones or keep this migration.
  //       for now we always run the down migration.
  // if (process.env.MIGRATE === "force" || hash_of_schema_file !== hash_of_current_schema)
  let exitCodeDown = await runDownMigrations(~shouldExit=false)
  // else
  //   await clearDb()

  let exitCodeUp = await runUpMigrations(~shouldExit=false)

  let exitCode = switch (exitCodeDown, exitCodeUp) {
  | (Success, Success) => Success
  | _ => Failure
  }

  process->exit(exitCode)
}
