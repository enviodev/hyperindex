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
        let generalTables = [TablesStatic.ChainMetadata.table]
        let enums = [Enums.EntityType.config->Internal.fromGenericEnumConfig]

        let queries = PgStorage.makeInitializeTransaction(
          ~pgSchema="test_schema",
          ~pgUser="postgres",
          ~generalTables,
          ~entities,
          ~enums,
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
CREATE TABLE IF NOT EXISTS "test_schema"."chain_metadata"("chain_id" INTEGER NOT NULL, "start_block" INTEGER NOT NULL, "end_block" INTEGER, "block_height" INTEGER NOT NULL, "first_event_block_number" INTEGER, "latest_processed_block" INTEGER, "num_events_processed" INTEGER, "is_hyper_sync" BOOLEAN NOT NULL, "num_batches_fetched" INTEGER NOT NULL, "latest_fetched_block_number" INTEGER NOT NULL, "timestamp_caught_up_to_head_or_endblock" TIMESTAMP WITH TIME ZONE NULL, PRIMARY KEY("chain_id"));
CREATE TABLE IF NOT EXISTS "test_schema"."A"("b_id" TEXT NOT NULL, "id" TEXT NOT NULL, "optionalStringToTestLinkedEntities" TEXT, "db_write_timestamp" TIMESTAMP DEFAULT CURRENT_TIMESTAMP, PRIMARY KEY("id"));
CREATE TABLE IF NOT EXISTS "test_schema"."A_history"("entity_history_block_timestamp" INTEGER NOT NULL, "entity_history_chain_id" INTEGER NOT NULL, "entity_history_block_number" INTEGER NOT NULL, "entity_history_log_index" INTEGER NOT NULL, "previous_entity_history_block_timestamp" INTEGER, "previous_entity_history_chain_id" INTEGER, "previous_entity_history_block_number" INTEGER, "previous_entity_history_log_index" INTEGER, "b_id" TEXT, "id" TEXT NOT NULL, "optionalStringToTestLinkedEntities" TEXT, "action" "test_schema".ENTITY_HISTORY_ROW_ACTION NOT NULL, "serial" SERIAL, PRIMARY KEY("entity_history_block_timestamp", "entity_history_chain_id", "entity_history_block_number", "entity_history_log_index", "id"));
CREATE TABLE IF NOT EXISTS "test_schema"."B"("c_id" TEXT, "id" TEXT NOT NULL, "db_write_timestamp" TIMESTAMP DEFAULT CURRENT_TIMESTAMP, PRIMARY KEY("id"));
CREATE TABLE IF NOT EXISTS "test_schema"."B_history"("entity_history_block_timestamp" INTEGER NOT NULL, "entity_history_chain_id" INTEGER NOT NULL, "entity_history_block_number" INTEGER NOT NULL, "entity_history_log_index" INTEGER NOT NULL, "previous_entity_history_block_timestamp" INTEGER, "previous_entity_history_chain_id" INTEGER, "previous_entity_history_block_number" INTEGER, "previous_entity_history_log_index" INTEGER, "c_id" TEXT, "id" TEXT NOT NULL, "action" "test_schema".ENTITY_HISTORY_ROW_ACTION NOT NULL, "serial" SERIAL, PRIMARY KEY("entity_history_block_timestamp", "entity_history_chain_id", "entity_history_block_number", "entity_history_log_index", "id"));
CREATE INDEX IF NOT EXISTS "A_b_id" ON "test_schema"."A"("b_id");
CREATE INDEX IF NOT EXISTS "A_history_serial" ON "test_schema"."A_history"("serial");
CREATE INDEX IF NOT EXISTS "B_history_serial" ON "test_schema"."B_history"("serial");
CREATE INDEX IF NOT EXISTS "A_b_id" ON "test_schema"."A"("b_id");`

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

        // Should return exactly 1 query (just main DDL, no functions)
        Assert.equal(
          queries->Array.length,
          1,
          ~message="Should return single query when no entities have functions",
        )

        let mainQuery = queries->Belt.Array.get(0)->Belt.Option.getExn

        let expectedMainQuery = `DROP SCHEMA IF EXISTS "test_schema" CASCADE;
CREATE SCHEMA "test_schema";
GRANT ALL ON SCHEMA "test_schema" TO "postgres";
GRANT ALL ON SCHEMA "test_schema" TO public;`

        Assert.equal(
          mainQuery,
          expectedMainQuery,
          ~message="Minimal configuration should match expected SQL exactly",
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
          ~generalTables=[],
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
          ~table=Entities.A.table,
          ~itemSchema=Entities.A.schema,
          ~isRawEvents=false,
        )

        let expectedQuery = `INSERT INTO "test_schema"."A" ("b_id", "id", "optionalStringToTestLinkedEntities")
SELECT * FROM unnest($1::TEXT[],$2::TEXT[],$3::TEXT[])ON CONFLICT("id") DO UPDATE SET "b_id" = EXCLUDED."b_id","optionalStringToTestLinkedEntities" = EXCLUDED."optionalStringToTestLinkedEntities";`

        Assert.equal(query, expectedQuery, ~message="Should generate correct unnest insert SQL")
      },
    )

    Async.it(
      "Should handle raw events table correctly",
      async () => {
        let query = PgStorage.makeInsertUnnestSetQuery(
          ~pgSchema="test_schema",
          ~table=Entities.A.table,
          ~itemSchema=Entities.A.schema,
          ~isRawEvents=true,
        )

        let expectedQuery = `INSERT INTO "test_schema"."A" ("b_id", "id", "optionalStringToTestLinkedEntities")
SELECT * FROM unnest($1::TEXT[],$2::TEXT[],$3::TEXT[]);`

        Assert.equal(
          query,
          expectedQuery,
          ~message="Should generate correct unnest insert SQL for raw events",
        )
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
})
