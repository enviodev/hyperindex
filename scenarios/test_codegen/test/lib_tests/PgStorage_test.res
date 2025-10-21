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
        let query = PgStorage.makeCreateTableQuery(
          Entities.A.table,
          ~pgSchema="test_schema",
          ~isNumericArrayAsText=false,
        )

        let expectedTableSql = `CREATE TABLE IF NOT EXISTS "test_schema"."A"("b_id" TEXT NOT NULL, "id" TEXT NOT NULL, "optionalStringToTestLinkedEntities" TEXT, PRIMARY KEY("id"));`
        Assert.equal(query, expectedTableSql, ~message="A table SQL should match exactly")
      },
    )

    Async.it(
      "Should create SQL for B entity table with derived fields",
      async () => {
        let query = PgStorage.makeCreateTableQuery(
          Entities.B.table,
          ~pgSchema="test_schema",
          ~isNumericArrayAsText=false,
        )

        let expectedBTableSql = `CREATE TABLE IF NOT EXISTS "test_schema"."B"("c_id" TEXT, "id" TEXT NOT NULL, PRIMARY KEY("id"));`
        Assert.equal(query, expectedBTableSql, ~message="B table SQL should match exactly")
      },
    )

    Async.it(
      "Should handle default values",
      async () => {
        let query = PgStorage.makeCreateTableQuery(
          Entities.A.table,
          ~pgSchema="test_schema",
          ~isNumericArrayAsText=false,
        )

        let expectedDefaultTestSql = `CREATE TABLE IF NOT EXISTS "test_schema"."A"("b_id" TEXT NOT NULL, "id" TEXT NOT NULL, "optionalStringToTestLinkedEntities" TEXT, PRIMARY KEY("id"));`
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
          module(
            Entities.EntityWith63LenghtName______________________________________one
          )->Entities.entityModToInternal,
          module(
            Entities.EntityWith63LenghtName______________________________________two
          )->Entities.entityModToInternal,
          module(Entities.EntityWithAllTypes)->Entities.entityModToInternal,
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
              maxReorgDepth: 10,
              contracts: [],
              sources: [],
            },
            {
              id: 137,
              startBlock: 0,
              maxReorgDepth: 200,
              contracts: [],
              sources: [],
            },
          ],
          // Because of the line arrayOfBigInts and arrayOfBigDecimals should become TEXT[] instead of NUMERIC[]
          // Related to https://github.com/enviodev/hyperindex/issues/788
          ~isHasuraEnabled=true,
        )

        // Should return exactly 2 queries: main DDL + functions
        Assert.equal(
          queries->Array.length,
          2,
          ~message="Should return exactly 2 queries for main DDL and functions",
        )

        let mainQuery = queries->Belt.Array.get(0)->Belt.Option.getExn

        let expectedMainQuery = `DROP SCHEMA IF EXISTS "test_schema" CASCADE;
CREATE SCHEMA "test_schema";
GRANT ALL ON SCHEMA "test_schema" TO "postgres";
GRANT ALL ON SCHEMA "test_schema" TO public;
CREATE TYPE "test_schema".ENTITY_TYPE AS ENUM('A', 'B', 'C', 'CustomSelectionTestPass', 'D', 'EntityWith63LenghtName______________________________________one', 'EntityWith63LenghtName______________________________________two', 'EntityWithAllNonArrayTypes', 'EntityWithAllTypes', 'EntityWithBigDecimal', 'EntityWithTimestamp', 'Gravatar', 'NftCollection', 'PostgresNumericPrecisionEntityTester', 'SimpleEntity', 'Token', 'User', 'dynamic_contract_registry');
CREATE TABLE IF NOT EXISTS "test_schema"."envio_chains"("id" INTEGER NOT NULL, "start_block" INTEGER NOT NULL, "end_block" INTEGER, "max_reorg_depth" INTEGER NOT NULL, "buffer_block" INTEGER NOT NULL, "source_block" INTEGER NOT NULL, "first_event_block" INTEGER, "ready_at" TIMESTAMP WITH TIME ZONE NULL, "events_processed" INTEGER NOT NULL, "_is_hyper_sync" BOOLEAN NOT NULL, "progress_block" INTEGER NOT NULL, "_num_batches_fetched" INTEGER NOT NULL, PRIMARY KEY("id"));
CREATE TABLE IF NOT EXISTS "test_schema"."persisted_state"("id" SERIAL NOT NULL, "envio_version" TEXT NOT NULL, "config_hash" TEXT NOT NULL, "schema_hash" TEXT NOT NULL, "handler_files_hash" TEXT NOT NULL, "abi_files_hash" TEXT NOT NULL, PRIMARY KEY("id"));
CREATE TABLE IF NOT EXISTS "test_schema"."envio_checkpoints"("id" INTEGER NOT NULL, "chain_id" INTEGER NOT NULL, "block_number" INTEGER NOT NULL, "block_hash" TEXT, "events_processed" INTEGER NOT NULL, PRIMARY KEY("id"));
CREATE TABLE IF NOT EXISTS "test_schema"."raw_events"("chain_id" INTEGER NOT NULL, "event_id" NUMERIC NOT NULL, "event_name" TEXT NOT NULL, "contract_name" TEXT NOT NULL, "block_number" INTEGER NOT NULL, "log_index" INTEGER NOT NULL, "src_address" TEXT NOT NULL, "block_hash" TEXT NOT NULL, "block_timestamp" INTEGER NOT NULL, "block_fields" JSONB NOT NULL, "transaction_fields" JSONB NOT NULL, "params" JSONB NOT NULL, "serial" SERIAL, PRIMARY KEY("serial"));
CREATE TABLE IF NOT EXISTS "test_schema"."A"("b_id" TEXT NOT NULL, "id" TEXT NOT NULL, "optionalStringToTestLinkedEntities" TEXT, PRIMARY KEY("id"));
CREATE TABLE IF NOT EXISTS "test_schema"."envio_history_A"("b_id" TEXT, "id" TEXT NOT NULL, "optionalStringToTestLinkedEntities" TEXT, "checkpoint_id" INTEGER NOT NULL, "envio_change" "test_schema".ENVIO_HISTORY_CHANGE NOT NULL, PRIMARY KEY("id", "checkpoint_id"));
CREATE TABLE IF NOT EXISTS "test_schema"."B"("c_id" TEXT, "id" TEXT NOT NULL, PRIMARY KEY("id"));
CREATE TABLE IF NOT EXISTS "test_schema"."envio_history_B"("c_id" TEXT, "id" TEXT NOT NULL, "checkpoint_id" INTEGER NOT NULL, "envio_change" "test_schema".ENVIO_HISTORY_CHANGE NOT NULL, PRIMARY KEY("id", "checkpoint_id"));
CREATE TABLE IF NOT EXISTS "test_schema"."EntityWith63LenghtName______________________________________one"("id" TEXT NOT NULL, PRIMARY KEY("id"));
CREATE TABLE IF NOT EXISTS "test_schema"."envio_history_EntityWith63LenghtName__________________________5"("id" TEXT NOT NULL, "checkpoint_id" INTEGER NOT NULL, "envio_change" "test_schema".ENVIO_HISTORY_CHANGE NOT NULL, PRIMARY KEY("id", "checkpoint_id"));
CREATE TABLE IF NOT EXISTS "test_schema"."EntityWith63LenghtName______________________________________two"("id" TEXT NOT NULL, PRIMARY KEY("id"));
CREATE TABLE IF NOT EXISTS "test_schema"."envio_history_EntityWith63LenghtName__________________________6"("id" TEXT NOT NULL, "checkpoint_id" INTEGER NOT NULL, "envio_change" "test_schema".ENVIO_HISTORY_CHANGE NOT NULL, PRIMARY KEY("id", "checkpoint_id"));
CREATE TABLE IF NOT EXISTS "test_schema"."EntityWithAllTypes"("arrayOfBigDecimals" TEXT[] NOT NULL, "arrayOfBigInts" TEXT[] NOT NULL, "arrayOfFloats" DOUBLE PRECISION[] NOT NULL, "arrayOfInts" INTEGER[] NOT NULL, "arrayOfStrings" TEXT[] NOT NULL, "bigDecimal" NUMERIC NOT NULL, "bigDecimalWithConfig" NUMERIC(10, 8) NOT NULL, "bigInt" NUMERIC NOT NULL, "bool" BOOLEAN NOT NULL, "enumField" "test_schema".AccountType NOT NULL, "float_" DOUBLE PRECISION NOT NULL, "id" TEXT NOT NULL, "int_" INTEGER NOT NULL, "json" JSONB NOT NULL, "optBigDecimal" NUMERIC, "optBigInt" NUMERIC, "optBool" BOOLEAN, "optEnumField" "test_schema".AccountType, "optFloat" DOUBLE PRECISION, "optInt" INTEGER, "optString" TEXT, "string" TEXT NOT NULL, PRIMARY KEY("id"));
CREATE TABLE IF NOT EXISTS "test_schema"."envio_history_EntityWithAllTypes"("arrayOfBigDecimals" TEXT[], "arrayOfBigInts" TEXT[], "arrayOfFloats" DOUBLE PRECISION[], "arrayOfInts" INTEGER[], "arrayOfStrings" TEXT[], "bigDecimal" NUMERIC, "bigDecimalWithConfig" NUMERIC(10, 8), "bigInt" NUMERIC, "bool" BOOLEAN, "enumField" "test_schema".AccountType, "float_" DOUBLE PRECISION, "id" TEXT NOT NULL, "int_" INTEGER, "json" JSONB, "optBigDecimal" NUMERIC, "optBigInt" NUMERIC, "optBool" BOOLEAN, "optEnumField" "test_schema".AccountType, "optFloat" DOUBLE PRECISION, "optInt" INTEGER, "optString" TEXT, "string" TEXT, "checkpoint_id" INTEGER NOT NULL, "envio_change" "test_schema".ENVIO_HISTORY_CHANGE NOT NULL, PRIMARY KEY("id", "checkpoint_id"));
CREATE INDEX IF NOT EXISTS "A_b_id" ON "test_schema"."A"("b_id");
CREATE INDEX IF NOT EXISTS "A_b_id" ON "test_schema"."A"("b_id");
CREATE VIEW "test_schema"."_meta" AS 
SELECT 
  "id" AS "chainId",
  "start_block" AS "startBlock", 
  "end_block" AS "endBlock",
  "progress_block" AS "progressBlock",
  "buffer_block" AS "bufferBlock",
  "first_event_block" AS "firstEventBlock",
  "events_processed" AS "eventsProcessed",
  "source_block" AS "sourceBlock",
  "ready_at" AS "readyAt",
  ("ready_at" IS NOT NULL) AS "isReady"
FROM "test_schema"."envio_chains"
ORDER BY "id";
CREATE VIEW "test_schema"."chain_metadata" AS 
SELECT 
  "source_block" AS "block_height",
  "id" AS "chain_id",
  "end_block" AS "end_block", 
  "first_event_block" AS "first_event_block_number",
  "_is_hyper_sync" AS "is_hyper_sync",
  "buffer_block" AS "latest_fetched_block_number",
  "progress_block" AS "latest_processed_block",
  "_num_batches_fetched" AS "num_batches_fetched",
  "events_processed" AS "num_events_processed",
  "start_block" AS "start_block",
  "ready_at" AS "timestamp_caught_up_to_head_or_endblock"
FROM "test_schema"."envio_chains";
INSERT INTO "test_schema"."envio_chains" ("id", "start_block", "end_block", "max_reorg_depth", "source_block", "first_event_block", "buffer_block", "progress_block", "ready_at", "events_processed", "_is_hyper_sync", "_num_batches_fetched")
VALUES (1, 100, 200, 10, 0, NULL, -1, -1, NULL, 0, false, 0),
       (137, 0, NULL, 200, 0, NULL, -1, -1, NULL, 0, false, 0);`

        Assert.equal(
          mainQuery,
          expectedMainQuery,
          ~message="Main query should match expected SQL exactly",
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
          ~isHasuraEnabled=false,
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
CREATE TABLE IF NOT EXISTS "test_schema"."envio_chains"("id" INTEGER NOT NULL, "start_block" INTEGER NOT NULL, "end_block" INTEGER, "max_reorg_depth" INTEGER NOT NULL, "buffer_block" INTEGER NOT NULL, "source_block" INTEGER NOT NULL, "first_event_block" INTEGER, "ready_at" TIMESTAMP WITH TIME ZONE NULL, "events_processed" INTEGER NOT NULL, "_is_hyper_sync" BOOLEAN NOT NULL, "progress_block" INTEGER NOT NULL, "_num_batches_fetched" INTEGER NOT NULL, PRIMARY KEY("id"));
CREATE TABLE IF NOT EXISTS "test_schema"."persisted_state"("id" SERIAL NOT NULL, "envio_version" TEXT NOT NULL, "config_hash" TEXT NOT NULL, "schema_hash" TEXT NOT NULL, "handler_files_hash" TEXT NOT NULL, "abi_files_hash" TEXT NOT NULL, PRIMARY KEY("id"));
CREATE TABLE IF NOT EXISTS "test_schema"."envio_checkpoints"("id" INTEGER NOT NULL, "chain_id" INTEGER NOT NULL, "block_number" INTEGER NOT NULL, "block_hash" TEXT, "events_processed" INTEGER NOT NULL, PRIMARY KEY("id"));
CREATE TABLE IF NOT EXISTS "test_schema"."raw_events"("chain_id" INTEGER NOT NULL, "event_id" NUMERIC NOT NULL, "event_name" TEXT NOT NULL, "contract_name" TEXT NOT NULL, "block_number" INTEGER NOT NULL, "log_index" INTEGER NOT NULL, "src_address" TEXT NOT NULL, "block_hash" TEXT NOT NULL, "block_timestamp" INTEGER NOT NULL, "block_fields" JSONB NOT NULL, "transaction_fields" JSONB NOT NULL, "params" JSONB NOT NULL, "serial" SERIAL, PRIMARY KEY("serial"));
CREATE VIEW "test_schema"."_meta" AS 
SELECT 
  "id" AS "chainId",
  "start_block" AS "startBlock", 
  "end_block" AS "endBlock",
  "progress_block" AS "progressBlock",
  "buffer_block" AS "bufferBlock",
  "first_event_block" AS "firstEventBlock",
  "events_processed" AS "eventsProcessed",
  "source_block" AS "sourceBlock",
  "ready_at" AS "readyAt",
  ("ready_at" IS NOT NULL) AS "isReady"
FROM "test_schema"."envio_chains"
ORDER BY "id";
CREATE VIEW "test_schema"."chain_metadata" AS 
SELECT 
  "source_block" AS "block_height",
  "id" AS "chain_id",
  "end_block" AS "end_block", 
  "first_event_block" AS "first_event_block_number",
  "_is_hyper_sync" AS "is_hyper_sync",
  "buffer_block" AS "latest_fetched_block_number",
  "progress_block" AS "latest_processed_block",
  "_num_batches_fetched" AS "num_batches_fetched",
  "events_processed" AS "num_events_processed",
  "start_block" AS "start_block",
  "ready_at" AS "timestamp_caught_up_to_head_or_endblock"
FROM "test_schema"."envio_chains";`

        Assert.equal(
          mainQuery,
          expectedMainQuery,
          ~message="Minimal configuration should match expected SQL exactly",
        )

        Assert.equal(
          queries->Belt.Array.get(1)->Belt.Option.getExn,
          `CREATE OR REPLACE FUNCTION get_cache_row_count(table_name text) 
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
          ~isHasuraEnabled=false,
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
CREATE TABLE IF NOT EXISTS "public"."envio_chains"("id" INTEGER NOT NULL, "start_block" INTEGER NOT NULL, "end_block" INTEGER, "max_reorg_depth" INTEGER NOT NULL, "buffer_block" INTEGER NOT NULL, "source_block" INTEGER NOT NULL, "first_event_block" INTEGER, "ready_at" TIMESTAMP WITH TIME ZONE NULL, "events_processed" INTEGER NOT NULL, "_is_hyper_sync" BOOLEAN NOT NULL, "progress_block" INTEGER NOT NULL, "_num_batches_fetched" INTEGER NOT NULL, PRIMARY KEY("id"));
CREATE TABLE IF NOT EXISTS "public"."persisted_state"("id" SERIAL NOT NULL, "envio_version" TEXT NOT NULL, "config_hash" TEXT NOT NULL, "schema_hash" TEXT NOT NULL, "handler_files_hash" TEXT NOT NULL, "abi_files_hash" TEXT NOT NULL, PRIMARY KEY("id"));
CREATE TABLE IF NOT EXISTS "public"."envio_checkpoints"("id" INTEGER NOT NULL, "chain_id" INTEGER NOT NULL, "block_number" INTEGER NOT NULL, "block_hash" TEXT, "events_processed" INTEGER NOT NULL, PRIMARY KEY("id"));
CREATE TABLE IF NOT EXISTS "public"."raw_events"("chain_id" INTEGER NOT NULL, "event_id" NUMERIC NOT NULL, "event_name" TEXT NOT NULL, "contract_name" TEXT NOT NULL, "block_number" INTEGER NOT NULL, "log_index" INTEGER NOT NULL, "src_address" TEXT NOT NULL, "block_hash" TEXT NOT NULL, "block_timestamp" INTEGER NOT NULL, "block_fields" JSONB NOT NULL, "transaction_fields" JSONB NOT NULL, "params" JSONB NOT NULL, "serial" SERIAL, PRIMARY KEY("serial"));
CREATE TABLE IF NOT EXISTS "public"."A"("b_id" TEXT NOT NULL, "id" TEXT NOT NULL, "optionalStringToTestLinkedEntities" TEXT, PRIMARY KEY("id"));
CREATE TABLE IF NOT EXISTS "public"."envio_history_A"("b_id" TEXT, "id" TEXT NOT NULL, "optionalStringToTestLinkedEntities" TEXT, "checkpoint_id" INTEGER NOT NULL, "envio_change" "public".ENVIO_HISTORY_CHANGE NOT NULL, PRIMARY KEY("id", "checkpoint_id"));
CREATE INDEX IF NOT EXISTS "A_b_id" ON "public"."A"("b_id");
CREATE VIEW "public"."_meta" AS 
SELECT 
  "id" AS "chainId",
  "start_block" AS "startBlock", 
  "end_block" AS "endBlock",
  "progress_block" AS "progressBlock",
  "buffer_block" AS "bufferBlock",
  "first_event_block" AS "firstEventBlock",
  "events_processed" AS "eventsProcessed",
  "source_block" AS "sourceBlock",
  "ready_at" AS "readyAt",
  ("ready_at" IS NOT NULL) AS "isReady"
FROM "public"."envio_chains"
ORDER BY "id";
CREATE VIEW "public"."chain_metadata" AS 
SELECT 
  "source_block" AS "block_height",
  "id" AS "chain_id",
  "end_block" AS "end_block", 
  "first_event_block" AS "first_event_block_number",
  "_is_hyper_sync" AS "is_hyper_sync",
  "buffer_block" AS "latest_fetched_block_number",
  "progress_block" AS "latest_processed_block",
  "_num_batches_fetched" AS "num_batches_fetched",
  "events_processed" AS "num_events_processed",
  "start_block" AS "start_block",
  "ready_at" AS "timestamp_caught_up_to_head_or_endblock"
FROM "public"."envio_chains";`

        Assert.equal(
          mainQuery,
          expectedMainQuery,
          ~message="Single entity SQL should match expected output exactly",
        )

        // Verify functions query contains the A history function
        Assert.equal(
          functionsQuery,
          `CREATE OR REPLACE FUNCTION get_cache_row_count(table_name text) 
RETURNS integer AS $$
DECLARE
  result integer;
BEGIN
  EXECUTE format('SELECT COUNT(*) FROM "public".%I', table_name) INTO result;
  RETURN result;
END;
$$ LANGUAGE plpgsql;`,
          ~message="Should contain cache row count function definition",
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

  describe("InternalTable.Chains.makeMetaFieldsUpdateQuery", () => {
    Async.it(
      "Should create correct SQL for updating chain state",
      async () => {
        let query = InternalTable.Chains.makeMetaFieldsUpdateQuery(~pgSchema="test_schema")

        let expectedQuery = `UPDATE "test_schema"."envio_chains"
SET "source_block" = $2,
    "buffer_block" = $3,
    "first_event_block" = $4,
    "ready_at" = $5,
    "_is_hyper_sync" = $6,
    "_num_batches_fetched" = $7
WHERE "id" = $1;`

        Assert.equal(
          query,
          expectedQuery,
          ~message="Should generate correct UPDATE SQL with parameter placeholders",
        )
      },
    )
  })

  describe("InternalTable.Chains.makeProgressFieldsUpdateQuery", () => {
    Async.it(
      "Should create correct SQL for updating chain progress fields",
      async () => {
        let query = InternalTable.Chains.makeProgressFieldsUpdateQuery(~pgSchema="test_schema")

        let expectedQuery = `UPDATE "test_schema"."envio_chains"
SET "progress_block" = $2,
    "events_processed" = $3
WHERE "id" = $1;`

        Assert.equal(
          query,
          expectedQuery,
          ~message="Should generate correct UPDATE SQL for progress fields with parameter placeholders",
        )
      },
    )
  })

  describe("InternalTable.Checkpoints.makeGetReorgCheckpointsQuery", () => {
    Async.it(
      "Should generate optimized SQL query with CTE",
      async () => {
        let query = InternalTable.Checkpoints.makeGetReorgCheckpointsQuery(~pgSchema="test_schema")

        // The query should use a CTE to pre-filter chains and compute safe_block
        let expectedQuery = `WITH reorg_chains AS (
  SELECT 
    "id" as id,
    "source_block" - "max_reorg_depth" AS safe_block
  FROM "test_schema"."envio_chains"
  WHERE "max_reorg_depth" > 0
    AND "progress_block" > "source_block" - "max_reorg_depth"
)
SELECT 
  cp."id", 
  cp."chain_id", 
  cp."block_number", 
  cp."block_hash"
FROM "test_schema"."envio_checkpoints" cp
INNER JOIN reorg_chains rc 
  ON cp."chain_id" = rc.id
WHERE cp."block_hash" IS NOT NULL
  AND cp."block_number" >= rc.safe_block;`

        Assert.equal(
          query,
          expectedQuery,
          ~message="Should generate optimized CTE query filtering chains outside reorg threshold",
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
          maxReorgDepth: 5,
          contracts: [],
          sources: [],
        }

        let query = InternalTable.Chains.makeInitialValuesQuery(
          ~pgSchema="test_schema",
          ~chainConfigs=[chainConfig],
        )

        let expectedQuery = `INSERT INTO "test_schema"."envio_chains" ("id", "start_block", "end_block", "max_reorg_depth", "source_block", "first_event_block", "buffer_block", "progress_block", "ready_at", "events_processed", "_is_hyper_sync", "_num_batches_fetched")
VALUES (1, 100, 200, 5, 0, NULL, -1, -1, NULL, 0, false, 0);`

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
          maxReorgDepth: 5,
          contracts: [],
          sources: [],
        }

        let query = InternalTable.Chains.makeInitialValuesQuery(
          ~pgSchema="public",
          ~chainConfigs=[chainConfig],
        )

        let expectedQuery = `INSERT INTO "public"."envio_chains" ("id", "start_block", "end_block", "max_reorg_depth", "source_block", "first_event_block", "buffer_block", "progress_block", "ready_at", "events_processed", "_is_hyper_sync", "_num_batches_fetched")
VALUES (1, 100, NULL, 5, 0, NULL, -1, -1, NULL, 0, false, 0);`

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
          maxReorgDepth: 5,
          contracts: [],
          sources: [],
        }

        let chainConfig2: InternalConfig.chain = {
          id: 42,
          startBlock: 500,
          maxReorgDepth: 0,
          contracts: [],
          sources: [],
        }

        let query = InternalTable.Chains.makeInitialValuesQuery(
          ~pgSchema="production",
          ~chainConfigs=[chainConfig1, chainConfig2],
        )

        let expectedQuery = `INSERT INTO "production"."envio_chains" ("id", "start_block", "end_block", "max_reorg_depth", "source_block", "first_event_block", "buffer_block", "progress_block", "ready_at", "events_processed", "_is_hyper_sync", "_num_batches_fetched")
VALUES (1, 100, 200, 5, 0, NULL, -1, -1, NULL, 0, false, 0),
       (42, 500, NULL, 0, 0, NULL, -1, -1, NULL, 0, false, 0);`

        Assert.equal(
          query,
          Some(expectedQuery),
          ~message="Should generate correct INSERT VALUES SQL for multiple chains",
        )
      },
    )
  })

  describe("InternalTable.Chains.makeGetInitialStateQuery", () => {
    Async.it(
      "Should create correct SQL for initial state query",
      async () => {
        let query = InternalTable.Chains.makeGetInitialStateQuery(~pgSchema="test_schema")

        let expectedQuery = `SELECT "id" as "id",
"start_block" as "startBlock",
"end_block" as "endBlock",
"max_reorg_depth" as "maxReorgDepth",
"first_event_block" as "firstEventBlockNumber",
"ready_at" as "timestampCaughtUpToHeadOrEndblock",
"events_processed" as "numEventsProcessed",
"progress_block" as "progressBlockNumber",
(
  SELECT COALESCE(json_agg(json_build_object(
    'address', "contract_address",
    'contractName', "contract_name",
    'startBlock', "registering_event_block_number",
    'registrationBlock', "registering_event_block_number"
  )), '[]'::json)
  FROM "test_schema"."dynamic_contract_registry"
  WHERE "chain_id" = chains."id"
) as "dynamicContracts"
FROM "test_schema"."envio_chains" as chains;`

        Assert.equal(query, expectedQuery, ~message="Initial state SQL should match exactly")
      },
    )
  })

  describe("InternalTable.Checkpoints.makeCommitedCheckpointIdQuery", () => {
    Async.it(
      "Should create correct SQL to get committed checkpoint id",
      async () => {
        let query = InternalTable.Checkpoints.makeCommitedCheckpointIdQuery(~pgSchema="test_schema")

        Assert.equal(
          query,
          `SELECT COALESCE(MAX(id), 0) AS id FROM "test_schema"."envio_checkpoints";`,
          ~message="Committed checkpoint id SQL should match exactly",
        )
      },
    )
  })

  describe("InternalTable.Checkpoints.makeInsertCheckpointQuery", () => {
    Async.it(
      "Should create correct SQL for inserting checkpoints with unnest",
      async () => {
        let query = InternalTable.Checkpoints.makeInsertCheckpointQuery(~pgSchema="test_schema")

        let expectedQuery = `INSERT INTO "test_schema"."envio_checkpoints" ("id", "chain_id", "block_number", "block_hash", "events_processed")
SELECT * FROM unnest($1::INTEGER[],$2::INTEGER[],$3::INTEGER[],$4::TEXT[],$5::INTEGER[]);`

        Assert.equal(query, expectedQuery, ~message="Insert checkpoints SQL should match exactly")
      },
    )
  })

  describe("InternalTable.Checkpoints.makePruneStaleCheckpointsQuery", () => {
    Async.it(
      "Should create correct SQL for pruning stale checkpoints",
      async () => {
        let query = InternalTable.Checkpoints.makePruneStaleCheckpointsQuery(
          ~pgSchema="test_schema",
        )

        Assert.equal(
          query,
          `DELETE FROM "test_schema"."envio_checkpoints" WHERE "id" < $1;`,
          ~message="Prune stale checkpoints SQL should match exactly",
        )
      },
    )
  })

  describe("InternalTable.Checkpoints.makeGetRollbackTargetCheckpointQuery", () => {
    Async.it(
      "Should create correct SQL for rollback target checkpoint",
      async () => {
        let query = InternalTable.Checkpoints.makeGetRollbackTargetCheckpointQuery(
          ~pgSchema="test_schema",
        )

        let expectedQuery = `SELECT "id" FROM "test_schema"."envio_checkpoints"
WHERE 
  "chain_id" = $1 AND
  "block_number" <= $2
ORDER BY "id" DESC
LIMIT 1;`

        Assert.equal(
          query,
          expectedQuery,
          ~message="Rollback target checkpoint SQL should match exactly",
        )
      },
    )
  })

  describe("InternalTable.Checkpoints.makeGetRollbackProgressDiffQuery", () => {
    Async.it(
      "Should create correct SQL for rollback progress diff",
      async () => {
        let query = InternalTable.Checkpoints.makeGetRollbackProgressDiffQuery(
          ~pgSchema="test_schema",
        )

        let expectedQuery = `SELECT 
  "chain_id",
  SUM("events_processed") as events_processed_diff,
  MIN("block_number") - 1 as new_progress_block_number
FROM "test_schema"."envio_checkpoints"
WHERE "id" > $1
GROUP BY "chain_id";`

        Assert.equal(
          query,
          expectedQuery,
          ~message="Rollback progress diff SQL should match exactly",
        )
      },
    )
  })
})
