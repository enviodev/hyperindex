open RescriptMocha

describe("Test PgStorage SQL generation functions", () => {
  describe("makeCreateIndexQuery", () => {
    Async.it(
      "Should create simple index SQL",
      async () => {
        let query = PgStorage.makeCreateIndexQuery(
          ~tableName="test_table",
          ~indexFields=["field1"],
          ~pgSchema="test_schema",
        )

        Assert.equal(
          query,
          `CREATE INDEX IF NOT EXISTS "test_table_field1" ON "test_schema"."test_table"("field1");`,
          ~message="Should generate correct single field index SQL",
        )
      },
    )

    Async.it(
      "Should create composite index SQL",
      async () => {
        let query = PgStorage.makeCreateIndexQuery(
          ~tableName="test_table",
          ~indexFields=["field1", "field2", "field3"],
          ~pgSchema="test_schema",
        )

        Assert.equal(
          query,
          `CREATE INDEX IF NOT EXISTS "test_table_field1_field2_field3" ON "test_schema"."test_table"("field1", "field2", "field3");`,
          ~message="Should generate correct composite index SQL",
        )
      },
    )
  })

  describe("makeCreateTableIndicesQuery", () => {
    Async.it(
      "Should create indices for A entity table",
      async () => {
        let query = PgStorage.makeCreateTableIndicesQuery(Entities.A.table, ~pgSchema="test_schema")

        let expectedIndices = `CREATE INDEX IF NOT EXISTS "A_b_id" ON "test_schema"."A"("b_id");`
        Assert.equal(query, expectedIndices, ~message="Indices SQL should match exactly")
      },
    )

    Async.it(
      "Should handle table with no indices",
      async () => {
        let query = PgStorage.makeCreateTableIndicesQuery(Entities.B.table, ~pgSchema="test_schema")

        // B entity has no indexed fields, so should return empty string
        Assert.equal(query, "", ~message="Should return empty string for table with no indices")
      },
    )
  })

  describe("makeCreateTableQuery", () => {
    Async.it(
      "Should create SQL for A entity table",
      async () => {
        let query = PgStorage.makeCreateTableQuery(Entities.A.table, ~pgSchema="test_schema")

        let expectedTableSql = `CREATE TABLE IF NOT EXISTS "test_schema"."A"("b_id" TEXT NOT NULL, "id" TEXT NOT NULL, "optionalStringToTestLinkedEntities" TEXT, "db_write_timestamp" TIMESTAMP DEFAULT CURRENT_TIMESTAMP, PRIMARY KEY("id"));`
        Assert.equal(query, expectedTableSql, ~message="A table SQL should match exactly")
      },
    )

    Async.it(
      "Should create SQL for B entity table with derived fields",
      async () => {
        let query = PgStorage.makeCreateTableQuery(Entities.B.table, ~pgSchema="test_schema")

        let expectedBTableSql = `CREATE TABLE IF NOT EXISTS "test_schema"."B"("c_id" TEXT, "id" TEXT NOT NULL, "db_write_timestamp" TIMESTAMP DEFAULT CURRENT_TIMESTAMP, PRIMARY KEY("id"));`
        Assert.equal(query, expectedBTableSql, ~message="B table SQL should match exactly")
      },
    )

    Async.it(
      "Should handle default values",
      async () => {
        let query = PgStorage.makeCreateTableQuery(Entities.A.table, ~pgSchema="test_schema")

        let expectedDefaultTestSql = `CREATE TABLE IF NOT EXISTS "test_schema"."A"("b_id" TEXT NOT NULL, "id" TEXT NOT NULL, "optionalStringToTestLinkedEntities" TEXT, "db_write_timestamp" TIMESTAMP DEFAULT CURRENT_TIMESTAMP, PRIMARY KEY("id"));`
        Assert.equal(
          query,
          expectedDefaultTestSql,
          ~message="Default value table SQL should match exactly",
        )
      },
    )
  })

  describe("makeInitializeTransaction", () => {
    Async.it(
      "Should create complete initialization queries",
      async () => {
        let entities = [
          module(Entities.A)->Entities.entityModToInternal,
          module(Entities.B)->Entities.entityModToInternal,
        ]
        let enums = [Enums.EntityType.config->Internal.fromGenericEnumConfig]

        let queries = PgStorage.makeInitializeTransaction(
          ~pgSchema="test_schema",
          ~pgUser="postgres",
          ~entities,
          ~enums,
          ~chainConfigs=[
            {
              id: 1,
              startBlock: 100,
              endBlock: 200,
              confirmedBlockThreshold: 10,
              contracts: [],
              sources: [],
            },
            {
              id: 137,
              startBlock: 0,
              confirmedBlockThreshold: 200,
              contracts: [],
              sources: [],
            },
          ],
        )

        // Should return exactly 2 queries: main DDL + functions
        Assert.equal(
          queries->Array.length,
          2,
          ~message="Should return exactly 2 queries for main DDL and functions",
        )

        let mainQuery = queries->Belt.Array.get(0)->Belt.Option.getExn
        let functionsQuery = queries->Belt.Array.get(1)->Belt.Option.getExn

        let expectedMainQuery = `DROP SCHEMA IF EXISTS "test_schema" CASCADE;
CREATE SCHEMA "test_schema";
GRANT ALL ON SCHEMA "test_schema" TO "postgres";
GRANT ALL ON SCHEMA "test_schema" TO public;
CREATE TYPE "test_schema".ENTITY_TYPE AS ENUM('A', 'B', 'C', 'CustomSelectionTestPass', 'D', 'EntityWithAllNonArrayTypes', 'EntityWithAllTypes', 'EntityWithBigDecimal', 'EntityWithTimestamp', 'Gravatar', 'NftCollection', 'PostgresNumericPrecisionEntityTester', 'Token', 'User', 'dynamic_contract_registry');
CREATE TABLE IF NOT EXISTS "test_schema"."event_sync_state"("chain_id" INTEGER NOT NULL, "block_number" INTEGER NOT NULL, "log_index" INTEGER NOT NULL, "block_timestamp" INTEGER NOT NULL, "is_pre_registering_dynamic_contracts" BOOLEAN DEFAULT false, PRIMARY KEY("chain_id"));
CREATE TABLE IF NOT EXISTS "test_schema"."envio_chains"("id" INTEGER NOT NULL, "start_block" INTEGER NOT NULL, "end_block" INTEGER, "buffer_block" INTEGER NOT NULL, "source_block" INTEGER NOT NULL, "first_event_block" INTEGER, "ready_at" TIMESTAMP WITH TIME ZONE NULL, "events_processed" INTEGER NOT NULL, "_is_hyper_sync" BOOLEAN NOT NULL, "_latest_processed_block" INTEGER, "_num_batches_fetched" INTEGER NOT NULL, PRIMARY KEY("id"));
CREATE TABLE IF NOT EXISTS "test_schema"."persisted_state"("id" SERIAL NOT NULL, "envio_version" TEXT NOT NULL, "config_hash" TEXT NOT NULL, "schema_hash" TEXT NOT NULL, "handler_files_hash" TEXT NOT NULL, "abi_files_hash" TEXT NOT NULL, PRIMARY KEY("id"));
CREATE TABLE IF NOT EXISTS "test_schema"."end_of_block_range_scanned_data"("chain_id" INTEGER NOT NULL, "block_number" INTEGER NOT NULL, "block_hash" TEXT NOT NULL, PRIMARY KEY("chain_id", "block_number"));
CREATE TABLE IF NOT EXISTS "test_schema"."raw_events"("chain_id" INTEGER NOT NULL, "event_id" NUMERIC NOT NULL, "event_name" TEXT NOT NULL, "contract_name" TEXT NOT NULL, "block_number" INTEGER NOT NULL, "log_index" INTEGER NOT NULL, "src_address" TEXT NOT NULL, "block_hash" TEXT NOT NULL, "block_timestamp" INTEGER NOT NULL, "block_fields" JSONB NOT NULL, "transaction_fields" JSONB NOT NULL, "params" JSONB NOT NULL, "db_write_timestamp" TIMESTAMP DEFAULT CURRENT_TIMESTAMP, "serial" SERIAL, PRIMARY KEY("serial"));
CREATE TABLE IF NOT EXISTS "test_schema"."A"("b_id" TEXT NOT NULL, "id" TEXT NOT NULL, "optionalStringToTestLinkedEntities" TEXT, "db_write_timestamp" TIMESTAMP DEFAULT CURRENT_TIMESTAMP, PRIMARY KEY("id"));
CREATE TABLE IF NOT EXISTS "test_schema"."A_history"("entity_history_block_timestamp" INTEGER NOT NULL, "entity_history_chain_id" INTEGER NOT NULL, "entity_history_block_number" INTEGER NOT NULL, "entity_history_log_index" INTEGER NOT NULL, "previous_entity_history_block_timestamp" INTEGER, "previous_entity_history_chain_id" INTEGER, "previous_entity_history_block_number" INTEGER, "previous_entity_history_log_index" INTEGER, "b_id" TEXT, "id" TEXT NOT NULL, "optionalStringToTestLinkedEntities" TEXT, "action" "test_schema".ENTITY_HISTORY_ROW_ACTION NOT NULL, "serial" SERIAL, PRIMARY KEY("entity_history_block_timestamp", "entity_history_chain_id", "entity_history_block_number", "entity_history_log_index", "id"));
CREATE TABLE IF NOT EXISTS "test_schema"."B"("c_id" TEXT, "id" TEXT NOT NULL, "db_write_timestamp" TIMESTAMP DEFAULT CURRENT_TIMESTAMP, PRIMARY KEY("id"));
CREATE TABLE IF NOT EXISTS "test_schema"."B_history"("entity_history_block_timestamp" INTEGER NOT NULL, "entity_history_chain_id" INTEGER NOT NULL, "entity_history_block_number" INTEGER NOT NULL, "entity_history_log_index" INTEGER NOT NULL, "previous_entity_history_block_timestamp" INTEGER, "previous_entity_history_chain_id" INTEGER, "previous_entity_history_block_number" INTEGER, "previous_entity_history_log_index" INTEGER, "c_id" TEXT, "id" TEXT NOT NULL, "action" "test_schema".ENTITY_HISTORY_ROW_ACTION NOT NULL, "serial" SERIAL, PRIMARY KEY("entity_history_block_timestamp", "entity_history_chain_id", "entity_history_block_number", "entity_history_log_index", "id"));
CREATE INDEX IF NOT EXISTS "A_b_id" ON "test_schema"."A"("b_id");
CREATE INDEX IF NOT EXISTS "A_history_serial" ON "test_schema"."A_history"("serial");
CREATE INDEX IF NOT EXISTS "B_history_serial" ON "test_schema"."B_history"("serial");
CREATE INDEX IF NOT EXISTS "A_b_id" ON "test_schema"."A"("b_id");
INSERT INTO "test_schema"."envio_chains" ("id", "start_block", "end_block", "source_block", "first_event_block", "buffer_block", "ready_at", "events_processed", "_is_hyper_sync", "_latest_processed_block", "_num_batches_fetched")
VALUES (1, 100, 200, 0, NULL, -1, NULL, 0, false, NULL, 0),
       (137, 0, NULL, 0, NULL, -1, NULL, 0, false, NULL, 0);`

        Assert.equal(
          mainQuery,
          expectedMainQuery,
          ~message="Main query should match expected SQL exactly",
        )

        // Functions query should contain both A and B history functions
        Assert.ok(
          functionsQuery->Js.String2.includes(`CREATE OR REPLACE FUNCTION "insert_A_history"`),
          ~message="Should contain A history function",
        )

        Assert.ok(
          functionsQuery->Js.String2.includes(`CREATE OR REPLACE FUNCTION "insert_B_history"`),
          ~message="Should contain B history function",
        )
      },
    )

    Async.it(
      "Should handle minimal configuration correctly",
      async () => {
        let queries = PgStorage.makeInitializeTransaction(
          ~pgSchema="test_schema",
          ~pgUser="postgres",
          ~enums=[],
        )

        // Should return exactly 2 query (main DDL, and a function for cache)
        Assert.equal(
          queries->Array.length,
          2,
          ~message="Should return single query when no entities have functions. And a function needed for cache.",
        )

        let mainQuery = queries->Belt.Array.get(0)->Belt.Option.getExn

        let expectedMainQuery = `DROP SCHEMA IF EXISTS "test_schema" CASCADE;
CREATE SCHEMA "test_schema";
GRANT ALL ON SCHEMA "test_schema" TO "postgres";
GRANT ALL ON SCHEMA "test_schema" TO public;
CREATE TABLE IF NOT EXISTS "test_schema"."event_sync_state"("chain_id" INTEGER NOT NULL, "block_number" INTEGER NOT NULL, "log_index" INTEGER NOT NULL, "block_timestamp" INTEGER NOT NULL, "is_pre_registering_dynamic_contracts" BOOLEAN DEFAULT false, PRIMARY KEY("chain_id"));
CREATE TABLE IF NOT EXISTS "test_schema"."envio_chains"("id" INTEGER NOT NULL, "start_block" INTEGER NOT NULL, "end_block" INTEGER, "buffer_block" INTEGER NOT NULL, "source_block" INTEGER NOT NULL, "first_event_block" INTEGER, "ready_at" TIMESTAMP WITH TIME ZONE NULL, "events_processed" INTEGER NOT NULL, "_is_hyper_sync" BOOLEAN NOT NULL, "_latest_processed_block" INTEGER, "_num_batches_fetched" INTEGER NOT NULL, PRIMARY KEY("id"));
CREATE TABLE IF NOT EXISTS "test_schema"."persisted_state"("id" SERIAL NOT NULL, "envio_version" TEXT NOT NULL, "config_hash" TEXT NOT NULL, "schema_hash" TEXT NOT NULL, "handler_files_hash" TEXT NOT NULL, "abi_files_hash" TEXT NOT NULL, PRIMARY KEY("id"));
CREATE TABLE IF NOT EXISTS "test_schema"."end_of_block_range_scanned_data"("chain_id" INTEGER NOT NULL, "block_number" INTEGER NOT NULL, "block_hash" TEXT NOT NULL, PRIMARY KEY("chain_id", "block_number"));
CREATE TABLE IF NOT EXISTS "test_schema"."raw_events"("chain_id" INTEGER NOT NULL, "event_id" NUMERIC NOT NULL, "event_name" TEXT NOT NULL, "contract_name" TEXT NOT NULL, "block_number" INTEGER NOT NULL, "log_index" INTEGER NOT NULL, "src_address" TEXT NOT NULL, "block_hash" TEXT NOT NULL, "block_timestamp" INTEGER NOT NULL, "block_fields" JSONB NOT NULL, "transaction_fields" JSONB NOT NULL, "params" JSONB NOT NULL, "db_write_timestamp" TIMESTAMP DEFAULT CURRENT_TIMESTAMP, "serial" SERIAL, PRIMARY KEY("serial"));`

        Assert.equal(
          mainQuery,
          expectedMainQuery,
          ~message="Minimal configuration should match expected SQL exactly",
        )

        Assert.equal(
          queries->Belt.Array.get(1)->Belt.Option.getExn,
          `
CREATE OR REPLACE FUNCTION get_cache_row_count(table_name text) 
RETURNS integer AS $$
DECLARE
  result integer;
BEGIN
  EXECUTE format('SELECT COUNT(*) FROM "test_schema".%I', table_name) INTO result;
  RETURN result;
END;
$$ LANGUAGE plpgsql;`,
          ~message="A function for cache should be created",
        )
      },
    )

    Async.it(
      "Should create SQL for single entity with indices",
      async () => {
        // Test with just entity A which has an indexed field
        let entities = [module(Entities.A)->Entities.entityModToInternal]

        let queries = PgStorage.makeInitializeTransaction(
          ~pgSchema="public",
          ~pgUser="postgres",
          ~entities,
          ~enums=[],
        )

        Assert.equal(
          queries->Array.length,
          2,
          ~message="Should return 2 queries for entity with history function",
        )

        let mainQuery = queries->Belt.Array.get(0)->Belt.Option.getExn
        let functionsQuery = queries->Belt.Array.get(1)->Belt.Option.getExn

        let expectedMainQuery = `DROP SCHEMA IF EXISTS "public" CASCADE;
CREATE SCHEMA "public";
GRANT ALL ON SCHEMA "public" TO "postgres";
GRANT ALL ON SCHEMA "public" TO public;
CREATE TABLE IF NOT EXISTS "public"."event_sync_state"("chain_id" INTEGER NOT NULL, "block_number" INTEGER NOT NULL, "log_index" INTEGER NOT NULL, "block_timestamp" INTEGER NOT NULL, "is_pre_registering_dynamic_contracts" BOOLEAN DEFAULT false, PRIMARY KEY("chain_id"));
CREATE TABLE IF NOT EXISTS "public"."envio_chains"("id" INTEGER NOT NULL, "start_block" INTEGER NOT NULL, "end_block" INTEGER, "buffer_block" INTEGER NOT NULL, "source_block" INTEGER NOT NULL, "first_event_block" INTEGER, "ready_at" TIMESTAMP WITH TIME ZONE NULL, "events_processed" INTEGER NOT NULL, "_is_hyper_sync" BOOLEAN NOT NULL, "_latest_processed_block" INTEGER, "_num_batches_fetched" INTEGER NOT NULL, PRIMARY KEY("id"));
CREATE TABLE IF NOT EXISTS "public"."persisted_state"("id" SERIAL NOT NULL, "envio_version" TEXT NOT NULL, "config_hash" TEXT NOT NULL, "schema_hash" TEXT NOT NULL, "handler_files_hash" TEXT NOT NULL, "abi_files_hash" TEXT NOT NULL, PRIMARY KEY("id"));
CREATE TABLE IF NOT EXISTS "public"."end_of_block_range_scanned_data"("chain_id" INTEGER NOT NULL, "block_number" INTEGER NOT NULL, "block_hash" TEXT NOT NULL, PRIMARY KEY("chain_id", "block_number"));
CREATE TABLE IF NOT EXISTS "public"."raw_events"("chain_id" INTEGER NOT NULL, "event_id" NUMERIC NOT NULL, "event_name" TEXT NOT NULL, "contract_name" TEXT NOT NULL, "block_number" INTEGER NOT NULL, "log_index" INTEGER NOT NULL, "src_address" TEXT NOT NULL, "block_hash" TEXT NOT NULL, "block_timestamp" INTEGER NOT NULL, "block_fields" JSONB NOT NULL, "transaction_fields" JSONB NOT NULL, "params" JSONB NOT NULL, "db_write_timestamp" TIMESTAMP DEFAULT CURRENT_TIMESTAMP, "serial" SERIAL, PRIMARY KEY("serial"));
CREATE TABLE IF NOT EXISTS "public"."A"("b_id" TEXT NOT NULL, "id" TEXT NOT NULL, "optionalStringToTestLinkedEntities" TEXT, "db_write_timestamp" TIMESTAMP DEFAULT CURRENT_TIMESTAMP, PRIMARY KEY("id"));
CREATE TABLE IF NOT EXISTS "public"."A_history"("entity_history_block_timestamp" INTEGER NOT NULL, "entity_history_chain_id" INTEGER NOT NULL, "entity_history_block_number" INTEGER NOT NULL, "entity_history_log_index" INTEGER NOT NULL, "previous_entity_history_block_timestamp" INTEGER, "previous_entity_history_chain_id" INTEGER, "previous_entity_history_block_number" INTEGER, "previous_entity_history_log_index" INTEGER, "b_id" TEXT, "id" TEXT NOT NULL, "optionalStringToTestLinkedEntities" TEXT, "action" "public".ENTITY_HISTORY_ROW_ACTION NOT NULL, "serial" SERIAL, PRIMARY KEY("entity_history_block_timestamp", "entity_history_chain_id", "entity_history_block_number", "entity_history_log_index", "id"));
CREATE INDEX IF NOT EXISTS "A_b_id" ON "public"."A"("b_id");
CREATE INDEX IF NOT EXISTS "A_history_serial" ON "public"."A_history"("serial");`

        Assert.equal(
          mainQuery,
          expectedMainQuery,
          ~message="Single entity SQL should match expected output exactly",
        )

        // Verify functions query contains the A history function
        Assert.ok(
          functionsQuery->Js.String2.includes(`CREATE OR REPLACE FUNCTION "insert_A_history"`),
          ~message="Should contain A history function definition",
        )
      },
    )
  })

  describe("makeLoadByIdQuery", () => {
    Async.it(
      "Should create correct SQL for loading single record by ID",
      async () => {
        let query = PgStorage.makeLoadByIdQuery(~pgSchema="test_schema", ~tableName="users")

        Assert.equal(
          query,
          `SELECT * FROM "test_schema"."users" WHERE id = $1 LIMIT 1;`,
          ~message="Should generate correct single ID query SQL",
        )
      },
    )

    Async.it(
      "Should handle different schema and table names",
      async () => {
        let query = PgStorage.makeLoadByIdQuery(~pgSchema="public", ~tableName="A")

        Assert.equal(
          query,
          `SELECT * FROM "public"."A" WHERE id = $1 LIMIT 1;`,
          ~message="Should generate correct SQL with different schema and table names",
        )
      },
    )
  })

  describe("makeLoadByIdsQuery", () => {
    Async.it(
      "Should create correct SQL for loading multiple records by IDs",
      async () => {
        let query = PgStorage.makeLoadByIdsQuery(~pgSchema="test_schema", ~tableName="users")

        Assert.equal(
          query,
          `SELECT * FROM "test_schema"."users" WHERE id = ANY($1::text[]);`,
          ~message="Should generate correct multiple IDs query SQL",
        )
      },
    )

    Async.it(
      "Should handle different schema and table names",
      async () => {
        let query = PgStorage.makeLoadByIdsQuery(~pgSchema="production", ~tableName="entities")

        Assert.equal(
          query,
          `SELECT * FROM "production"."entities" WHERE id = ANY($1::text[]);`,
          ~message="Should generate correct SQL with different schema and table names",
        )
      },
    )
  })

  describe("makeInsertUnnestSetQuery", () => {
    Async.it(
      "Should create correct SQL for inserting with unnest",
      async () => {
        let query = PgStorage.makeInsertUnnestSetQuery(
          ~pgSchema="test_schema",
          ~table=Entities.EntityWithAllNonArrayTypes.table,
          ~itemSchema=Entities.EntityWithAllNonArrayTypes.schema,
          ~isRawEvents=false,
        )

        let expectedQuery = `INSERT INTO "test_schema"."EntityWithAllNonArrayTypes" ("bigDecimal", "bigDecimalWithConfig", "bigInt", "bool", "enumField", "float_", "id", "int_", "optBigDecimal", "optBigInt", "optBool", "optEnumField", "optFloat", "optInt", "optString", "string")
SELECT * FROM unnest($1::NUMERIC[],$2::NUMERIC(10, 8)[],$3::NUMERIC[],$4::INTEGER[]::BOOLEAN[],$5::TEXT[]::"test_schema".AccountType[],$6::DOUBLE PRECISION[],$7::TEXT[],$8::INTEGER[],$9::NUMERIC[],$10::NUMERIC[],$11::INTEGER[]::BOOLEAN[],$12::TEXT[]::"test_schema".AccountType[],$13::DOUBLE PRECISION[],$14::INTEGER[],$15::TEXT[],$16::TEXT[])ON CONFLICT("id") DO UPDATE SET "bigDecimal" = EXCLUDED."bigDecimal","bigDecimalWithConfig" = EXCLUDED."bigDecimalWithConfig","bigInt" = EXCLUDED."bigInt","bool" = EXCLUDED."bool","enumField" = EXCLUDED."enumField","float_" = EXCLUDED."float_","int_" = EXCLUDED."int_","optBigDecimal" = EXCLUDED."optBigDecimal","optBigInt" = EXCLUDED."optBigInt","optBool" = EXCLUDED."optBool","optEnumField" = EXCLUDED."optEnumField","optFloat" = EXCLUDED."optFloat","optInt" = EXCLUDED."optInt","optString" = EXCLUDED."optString","string" = EXCLUDED."string";`

        Assert.equal(query, expectedQuery, ~message="Should generate correct unnest insert SQL")
      },
    )

    Async.it(
      "Should handle raw events table correctly",
      async () => {
        let query = PgStorage.makeInsertUnnestSetQuery(
          ~pgSchema="test_schema",
          ~table=InternalTable.RawEvents.table,
          ~itemSchema=InternalTable.RawEvents.schema,
          ~isRawEvents=true,
        )

        let expectedQuery = `INSERT INTO "test_schema"."raw_events" ("chain_id", "event_id", "event_name", "contract_name", "block_number", "log_index", "src_address", "block_hash", "block_timestamp", "block_fields", "transaction_fields", "params")
SELECT * FROM unnest($1::INTEGER[],$2::NUMERIC[],$3::TEXT[],$4::TEXT[],$5::INTEGER[],$6::INTEGER[],$7::TEXT[],$8::TEXT[],$9::INTEGER[],$10::JSONB[],$11::JSONB[],$12::JSONB[]);`

        Assert.equal(query, expectedQuery, ~message="Don't need EXCLUDED for raw events")
      },
    )
  })

  describe("makeInsertValuesSetQuery", () => {
    Async.it(
      "Should create correct SQL for inserting with values",
      async () => {
        let query = PgStorage.makeInsertValuesSetQuery(
          ~pgSchema="test_schema",
          ~table=Entities.A.table,
          ~itemSchema=Entities.A.schema,
          ~itemsCount=2,
        )

        let expectedQuery = `INSERT INTO "test_schema"."A" ("b_id", "id", "optionalStringToTestLinkedEntities")
VALUES($1,$3,$5),($2,$4,$6)ON CONFLICT("id") DO UPDATE SET "b_id" = EXCLUDED."b_id","optionalStringToTestLinkedEntities" = EXCLUDED."optionalStringToTestLinkedEntities";`

        Assert.equal(
          query,
          expectedQuery,
          ~message=`Should generate correct values insert SQL.
        The $x in the order, because we flatten unnested entities for the query`,
        )
      },
    )

    Async.it(
      "Should handle table without primary key",
      async () => {
        let query = PgStorage.makeInsertValuesSetQuery(
          ~pgSchema="test_schema",
          ~table=Entities.B.table,
          ~itemSchema=Entities.B.schema,
          ~itemsCount=1,
        )

        let expectedQuery = `INSERT INTO "test_schema"."B" ("c_id", "id")
VALUES($1,$2)ON CONFLICT("id") DO UPDATE SET "c_id" = EXCLUDED."c_id";`

        Assert.equal(
          query,
          expectedQuery,
          ~message="Should generate correct values insert SQL for table without primary key",
        )
      },
    )
  })

  describe("InternalTable.Chains.makeSingleUpdateQuery", () => {
    Async.it(
      "Should create correct SQL for updating chain state",
      async () => {
        let query = InternalTable.Chains.makeSingleUpdateQuery(~pgSchema="test_schema")

        let expectedQuery = `UPDATE "test_schema"."envio_chains"
SET "source_block" = $2,
    "first_event_block" = $3,
    "buffer_block" = $4,
    "ready_at" = $5,
    "events_processed" = $6,
    "_is_hyper_sync" = $7,
    "_latest_processed_block" = $8,
    "_num_batches_fetched" = $9
WHERE "id" = $1;`

        Assert.equal(
          query,
          expectedQuery,
          ~message="Should generate correct UPDATE SQL with parameter placeholders",
        )
      },
    )
  })

  describe("InternalTable.Chains.makeInitialValuesQuery", () => {
    Async.it(
      "Should return empty string for empty chain configs",
      async () => {
        let query = InternalTable.Chains.makeInitialValuesQuery(
          ~pgSchema="test_schema",
          ~chainConfigs=[],
        )

        Assert.equal(
          query,
          None,
          ~message="Should return empty string when no chain configs provided",
        )
      },
    )

    Async.it(
      "Should create correct SQL for single chain config",
      async () => {
        let chainConfig: InternalConfig.chain = {
          id: 1,
          startBlock: 100,
          endBlock: 200,
          confirmedBlockThreshold: 5,
          contracts: [],
          sources: [],
        }

        let query = InternalTable.Chains.makeInitialValuesQuery(
          ~pgSchema="test_schema",
          ~chainConfigs=[chainConfig],
        )

        let expectedQuery = `INSERT INTO "test_schema"."envio_chains" ("id", "start_block", "end_block", "source_block", "first_event_block", "buffer_block", "ready_at", "events_processed", "_is_hyper_sync", "_latest_processed_block", "_num_batches_fetched")
VALUES (1, 100, 200, 0, NULL, -1, NULL, 0, false, NULL, 0);`

        Assert.equal(
          query,
          Some(expectedQuery),
          ~message="Should generate correct INSERT VALUES SQL for single chain",
        )
      },
    )

    Async.it(
      "Should create correct SQL for single chain config with no end block",
      async () => {
        let chainConfig: InternalConfig.chain = {
          id: 1,
          startBlock: 100,
          confirmedBlockThreshold: 5,
          contracts: [],
          sources: [],
        }

        let query = InternalTable.Chains.makeInitialValuesQuery(
          ~pgSchema="public",
          ~chainConfigs=[chainConfig],
        )

        let expectedQuery = `INSERT INTO "public"."envio_chains" ("id", "start_block", "end_block", "source_block", "first_event_block", "buffer_block", "ready_at", "events_processed", "_is_hyper_sync", "_latest_processed_block", "_num_batches_fetched")
VALUES (1, 100, NULL, 0, NULL, -1, NULL, 0, false, NULL, 0);`

        Assert.equal(
          query,
          Some(expectedQuery),
          ~message="Should generate correct INSERT VALUES SQL with NULL end_block",
        )
      },
    )

    Async.it(
      "Should create correct SQL for multiple chain configs",
      async () => {
        let chainConfig1: InternalConfig.chain = {
          id: 1,
          startBlock: 100,
          endBlock: 200,
          confirmedBlockThreshold: 5,
          contracts: [],
          sources: [],
        }

        let chainConfig2: InternalConfig.chain = {
          id: 42,
          startBlock: 500,
          confirmedBlockThreshold: 0,
          contracts: [],
          sources: [],
        }

        let query = InternalTable.Chains.makeInitialValuesQuery(
          ~pgSchema="production",
          ~chainConfigs=[chainConfig1, chainConfig2],
        )

        let expectedQuery = `INSERT INTO "production"."envio_chains" ("id", "start_block", "end_block", "source_block", "first_event_block", "buffer_block", "ready_at", "events_processed", "_is_hyper_sync", "_latest_processed_block", "_num_batches_fetched")
VALUES (1, 100, 200, 0, NULL, -1, NULL, 0, false, NULL, 0),
       (42, 500, NULL, 0, NULL, -1, NULL, 0, false, NULL, 0);`

        Assert.equal(
          query,
          Some(expectedQuery),
          ~message="Should generate correct INSERT VALUES SQL for multiple chains",
        )
      },
    )

    Async.it(
      "Should use hardcoded values as specified",
      async () => {
        let chainConfig: InternalConfig.chain = {
          id: 1,
          startBlock: 1000,
          endBlock: 2000,
          confirmedBlockThreshold: 10,
          contracts: [],
          sources: [],
        }

        let query =
          InternalTable.Chains.makeInitialValuesQuery(
            ~pgSchema="test_schema",
            ~chainConfigs=[chainConfig],
          )->Belt.Option.getExn

        // Verify the hardcoded values are correct:
        // source_block: -1
        // buffer_block: -1
        // events_processed: 0
        // first_event_block: NULL
        // ready_at: NULL
        // _is_hyper_sync: false
        // _num_batches_fetched: 0
        // _latest_processed_block: NULL
        Assert.ok(
          query->Js.String2.includes(
            "VALUES (1, 1000, 2000, 0, NULL, -1, NULL, 0, false, NULL, 0)",
          ),
          ~message="Should contain all hardcoded values as specified",
        )
      },
    )
  })
})
