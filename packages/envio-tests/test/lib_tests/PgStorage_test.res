open Vitest

// Every scalar the DDL knows how to render, an entity whose name is over
// Postgres' 63-character table-name limit, and a foreign key that carries an
// index — the shapes the generated SQL below is asserted against.
let config = TestConfig.make(
  ~schema=`
enum AccountType {
  ADMIN
  USER
}

enum GravatarSize {
  SMALL
  MEDIUM
  LARGE
}

type Gravatar {
  id: ID!
  size: GravatarSize!
}

type A {
  id: ID!
  b: B! @index
  optionalStringToTestLinkedEntities: String
}

type B {
  id: ID!
  a: [A!]! @derivedFrom(field: "b")
  c: C
}

type C {
  id: ID!
  a: A!
  stringThatIsMirroredToA: String!
}

type EntityWith63LenghtName______________________________________one {
  id: ID!
}

type EntityWith63LenghtName______________________________________two {
  id: ID!
}

type EntityWithAllTypes {
  id: ID!
  string: String!
  optString: String
  arrayOfStrings: [String!]!
  int_: Int!
  optInt: Int
  arrayOfInts: [Int!]!
  float_: Float!
  optFloat: Float
  arrayOfFloats: [Float!]!
  bool: Boolean!
  optBool: Boolean
  bigInt: BigInt!
  optBigInt: BigInt
  arrayOfBigInts: [BigInt!]!
  bigDecimal: BigDecimal!
  optBigDecimal: BigDecimal
  bigDecimalWithConfig: BigDecimal! @config(precision: 10, scale: 8)
  arrayOfBigDecimals: [BigDecimal!]!
  timestamp: Timestamp!
  optTimestamp: Timestamp
  json: Json!
  enumField: AccountType!
  optEnumField: AccountType
}

type EntityWithAllNonArrayTypes {
  id: ID!
  string: String!
  optString: String
  int_: Int!
  optInt: Int
  float_: Float!
  optFloat: Float
  bool: Boolean!
  optBool: Boolean
  bigInt: BigInt!
  optBigInt: BigInt
  bigDecimal: BigDecimal!
  optBigDecimal: BigDecimal
  bigDecimalWithConfig: BigDecimal! @config(precision: 10, scale: 8)
  enumField: AccountType!
  optEnumField: AccountType
  timestamp: Timestamp!
  optTimestamp: Timestamp
}
`,
)

let ecosystem = config.ecosystem
let entityConfig = (name: string): Internal.entityConfig =>
  config->IndexerRunner.entityConfigByName(name)

describe("Test PgStorage SQL generation functions", () => {
  describe("makeCreateTableQuery", () => {
    Async.it(
      "Should create SQL for A entity table",
      async t => {
        let query = PgStorage.makeCreateTableQuery(
          entityConfig("A").table,
          ~pgSchema="test_schema",
          ~isNumericArrayAsText=false,
        )

        let expectedTableSql = `CREATE TABLE IF NOT EXISTS "test_schema"."A"("id" TEXT NOT NULL, "b_id" TEXT NOT NULL, "optionalStringToTestLinkedEntities" TEXT, PRIMARY KEY("id"));`
        t.expect(query, ~message="A table SQL should match exactly").toBe(expectedTableSql)
      },
    )

    Async.it(
      "Should create SQL for B entity table with derived fields",
      async t => {
        let query = PgStorage.makeCreateTableQuery(
          entityConfig("B").table,
          ~pgSchema="test_schema",
          ~isNumericArrayAsText=false,
        )

        let expectedBTableSql = `CREATE TABLE IF NOT EXISTS "test_schema"."B"("id" TEXT NOT NULL, "c_id" TEXT, PRIMARY KEY("id"));`
        t.expect(query, ~message="B table SQL should match exactly").toBe(expectedBTableSql)
      },
    )

    Async.it(
      "Should handle default values",
      async t => {
        let query = PgStorage.makeCreateTableQuery(
          entityConfig("A").table,
          ~pgSchema="test_schema",
          ~isNumericArrayAsText=false,
        )

        let expectedDefaultTestSql = `CREATE TABLE IF NOT EXISTS "test_schema"."A"("id" TEXT NOT NULL, "b_id" TEXT NOT NULL, "optionalStringToTestLinkedEntities" TEXT, PRIMARY KEY("id"));`
        t.expect(query, ~message="Default value table SQL should match exactly").toBe(
          expectedDefaultTestSql,
        )
      },
    )
  })

  // https://github.com/enviodev/hyperindex/pull/1595#discussion_r3861606904
  describe("historyTableName", () => {
    Async.it(
      "Keeps two truncated names apart when their entity indexes differ in length",
      async t => {
        // Both names share the 47 characters that survive truncation, and the
        // first one's next character is the leading digit of the second one's
        // index. With nothing marking where the name stops and the index
        // starts, "…B" + "11" and "…B1" + "1" are the same identifier, and
        // `CREATE TABLE IF NOT EXISTS` would quietly give both entities one
        // history table.
        let shared = "B"->String.repeat(47)
        let name = EntityHistory.historyTableName
        let first = name(~entityName=shared ++ "1AA", ~entityIndex=1)
        let second = name(~entityName=shared ++ "2BB", ~entityIndex=11)
        t.expect((first === second, first->String.length, second->String.length)).toEqual((
          false,
          Table.maxPgTableNameLength,
          Table.maxPgTableNameLength,
        ))
      },
    )
  })

  describe("makeInitializeTransaction", () => {
    Async.it(
      "Should create complete initialization queries",
      async t => {
        let entities = [
          entityConfig("A"),
          entityConfig("B"),
          entityConfig("EntityWith63LenghtName______________________________________one"),
          entityConfig("EntityWith63LenghtName______________________________________two"),
          entityConfig("EntityWithAllTypes"),
        ]
        let enums = config.allEnums

        let queries = PgStorage.makeInitializeTransaction(
          ~pgSchema="test_schema",
          ~pgUser="postgres",
          ~entities,
          ~enums,
          ~chainConfigs=[
            {
              name: "Chain1",
              id: 1->ChainId.fromInt,
              ecosystem: Ecosystem.Evm,
              startBlock: 100,
              endBlock: 200,
              maxReorgDepth: 10,
              blockLag: 0,
              contracts: [],
              sourceConfig: Config.CustomSources([]),
            },
            {
              name: "Chain137",
              id: 137->ChainId.fromInt,
              ecosystem: Ecosystem.Evm,
              startBlock: 0,
              maxReorgDepth: 200,
              blockLag: 0,
              contracts: [],
              sourceConfig: Config.CustomSources([]),
            },
          ],
          // Because of the line arrayOfBigInts and arrayOfBigDecimals should become TEXT[] instead of NUMERIC[]
          // Related to https://github.com/enviodev/hyperindex/issues/788
          ~isHasuraEnabled=true,
        )

        t.expect(queries->Array.length, ~message="Should return a single main DDL query").toBe(1)

        let mainQuery = queries->Array.get(0)->Option.getOrThrow

        let expectedMainQuery = `DROP SCHEMA IF EXISTS "test_schema" CASCADE;
CREATE SCHEMA "test_schema";
GRANT ALL ON SCHEMA "test_schema" TO "postgres";
GRANT ALL ON SCHEMA "test_schema" TO public;
CREATE TYPE "test_schema".AccountType AS ENUM('ADMIN', 'USER');
CREATE TYPE "test_schema".GravatarSize AS ENUM('SMALL', 'MEDIUM', 'LARGE');
CREATE TABLE IF NOT EXISTS "test_schema"."envio_chains"("id" INTEGER NOT NULL, "ecosystem" TEXT NOT NULL, "start_block" INTEGER NOT NULL, "end_block" INTEGER, "max_reorg_depth" INTEGER NOT NULL, "buffer_block" INTEGER NOT NULL, "source_block" INTEGER NOT NULL, "first_event_block" INTEGER, "ready_at" TIMESTAMP WITH TIME ZONE NULL, "events_processed" BIGINT NOT NULL, "_is_hyper_sync" BOOLEAN NOT NULL, "progress_block" INTEGER NOT NULL, PRIMARY KEY("id"));
CREATE TABLE IF NOT EXISTS "test_schema"."envio_info"("id" INTEGER DEFAULT 1, "config" TEXT NOT NULL, PRIMARY KEY("id"));
CREATE TABLE IF NOT EXISTS "test_schema"."envio_contracts"("id" SMALLINT NOT NULL, "name" TEXT NOT NULL, PRIMARY KEY("id"));
CREATE TABLE IF NOT EXISTS "test_schema"."envio_addresses"("chain_id" INTEGER NOT NULL, "address" BYTEA NOT NULL, "contract_id" SMALLINT NOT NULL, "registration_block" INTEGER NOT NULL, PRIMARY KEY("chain_id", "address", "contract_id"));
CREATE TABLE IF NOT EXISTS "test_schema"."envio_checkpoints"("id" BIGINT NOT NULL, "chain_id" INTEGER NOT NULL, "block_number" INTEGER NOT NULL, "block_hash" TEXT, "events_processed" INTEGER NOT NULL, PRIMARY KEY("id"));
CREATE TABLE IF NOT EXISTS "test_schema"."raw_events"("chain_id" INTEGER NOT NULL, "event_id" BIGINT NOT NULL, "event_name" TEXT NOT NULL, "contract_name" TEXT NOT NULL, "block_number" INTEGER NOT NULL, "log_index" INTEGER NOT NULL, "src_address" TEXT NOT NULL, "block_hash" TEXT NOT NULL, "block_timestamp" INTEGER NOT NULL, "block_fields" JSONB NOT NULL, "transaction_fields" JSONB NOT NULL, "params" JSONB NOT NULL, "serial" BIGSERIAL, PRIMARY KEY("serial"));
CREATE TABLE IF NOT EXISTS "test_schema"."A"("id" TEXT NOT NULL, "b_id" TEXT NOT NULL, "optionalStringToTestLinkedEntities" TEXT, PRIMARY KEY("id"));
CREATE TABLE IF NOT EXISTS "test_schema"."envio_history_A"("id" TEXT NOT NULL, "b_id" TEXT, "optionalStringToTestLinkedEntities" TEXT, "envio_checkpoint_id" BIGINT NOT NULL, "envio_change" "test_schema".ENVIO_HISTORY_CHANGE NOT NULL, PRIMARY KEY("id", "envio_checkpoint_id"));
CREATE TABLE IF NOT EXISTS "test_schema"."B"("id" TEXT NOT NULL, "c_id" TEXT, PRIMARY KEY("id"));
CREATE TABLE IF NOT EXISTS "test_schema"."envio_history_B"("id" TEXT NOT NULL, "c_id" TEXT, "envio_checkpoint_id" BIGINT NOT NULL, "envio_change" "test_schema".ENVIO_HISTORY_CHANGE NOT NULL, PRIMARY KEY("id", "envio_checkpoint_id"));
CREATE TABLE IF NOT EXISTS "test_schema"."EntityWith63LenghtName______________________________________one"("id" TEXT NOT NULL, PRIMARY KEY("id"));
CREATE TABLE IF NOT EXISTS "test_schema"."envio_history_EntityWith63LenghtName_________________________$3"("id" TEXT NOT NULL, "envio_checkpoint_id" BIGINT NOT NULL, "envio_change" "test_schema".ENVIO_HISTORY_CHANGE NOT NULL, PRIMARY KEY("id", "envio_checkpoint_id"));
CREATE TABLE IF NOT EXISTS "test_schema"."EntityWith63LenghtName______________________________________two"("id" TEXT NOT NULL, PRIMARY KEY("id"));
CREATE TABLE IF NOT EXISTS "test_schema"."envio_history_EntityWith63LenghtName_________________________$4"("id" TEXT NOT NULL, "envio_checkpoint_id" BIGINT NOT NULL, "envio_change" "test_schema".ENVIO_HISTORY_CHANGE NOT NULL, PRIMARY KEY("id", "envio_checkpoint_id"));
CREATE TABLE IF NOT EXISTS "test_schema"."EntityWithAllTypes"("id" TEXT NOT NULL, "string" TEXT NOT NULL, "optString" TEXT, "arrayOfStrings" TEXT[] NOT NULL, "int_" INTEGER NOT NULL, "optInt" INTEGER, "arrayOfInts" INTEGER[] NOT NULL, "float_" DOUBLE PRECISION NOT NULL, "optFloat" DOUBLE PRECISION, "arrayOfFloats" DOUBLE PRECISION[] NOT NULL, "bool" BOOLEAN NOT NULL, "optBool" BOOLEAN, "bigInt" NUMERIC NOT NULL, "optBigInt" NUMERIC, "arrayOfBigInts" TEXT[] NOT NULL, "bigDecimal" NUMERIC NOT NULL, "optBigDecimal" NUMERIC, "bigDecimalWithConfig" NUMERIC(10, 8) NOT NULL, "arrayOfBigDecimals" TEXT[] NOT NULL, "timestamp" TIMESTAMP WITH TIME ZONE NOT NULL, "optTimestamp" TIMESTAMP WITH TIME ZONE NULL, "json" JSONB NOT NULL, "enumField" "test_schema".AccountType NOT NULL, "optEnumField" "test_schema".AccountType, PRIMARY KEY("id"));
CREATE TABLE IF NOT EXISTS "test_schema"."envio_history_EntityWithAllTypes"("id" TEXT NOT NULL, "string" TEXT, "optString" TEXT, "arrayOfStrings" TEXT[], "int_" INTEGER, "optInt" INTEGER, "arrayOfInts" INTEGER[], "float_" DOUBLE PRECISION, "optFloat" DOUBLE PRECISION, "arrayOfFloats" DOUBLE PRECISION[], "bool" BOOLEAN, "optBool" BOOLEAN, "bigInt" NUMERIC, "optBigInt" NUMERIC, "arrayOfBigInts" TEXT[], "bigDecimal" NUMERIC, "optBigDecimal" NUMERIC, "bigDecimalWithConfig" NUMERIC(10, 8), "arrayOfBigDecimals" TEXT[], "timestamp" TIMESTAMP WITH TIME ZONE NULL, "optTimestamp" TIMESTAMP WITH TIME ZONE NULL, "json" JSONB, "enumField" "test_schema".AccountType, "optEnumField" "test_schema".AccountType, "envio_checkpoint_id" BIGINT NOT NULL, "envio_change" "test_schema".ENVIO_HISTORY_CHANGE NOT NULL, PRIMARY KEY("id", "envio_checkpoint_id"));
CREATE INDEX "${IndexDefinition.single(
            ~tableName="A",
            ~column="b_id",
          )->IndexDefinition.name}" ON "test_schema"."A"("b_id");
CREATE VIEW "test_schema"."_meta" AS 
SELECT 
  "id" AS "chainId",
  "ecosystem" AS "ecosystem",
  "start_block" AS "startBlock", 
  "end_block" AS "endBlock",
  "progress_block" AS "progressBlock",
  "buffer_block" AS "bufferBlock",
  "first_event_block" AS "firstEventBlock",
  "events_processed"::float4 AS "eventsProcessed",
  "source_block" AS "sourceBlock",
  "ready_at" AS "readyAt",
  ("ready_at" IS NOT NULL) AS "isReady"
FROM "test_schema"."envio_chains"
ORDER BY "id";
CREATE VIEW "test_schema"."chain_metadata" AS 
SELECT 
  "source_block" AS "block_height",
  "id" AS "chain_id",
  "ecosystem" AS "ecosystem",
  "end_block" AS "end_block", 
  "first_event_block" AS "first_event_block_number",
  "_is_hyper_sync" AS "is_hyper_sync",
  "buffer_block" AS "latest_fetched_block_number",
  "progress_block" AS "latest_processed_block",
  0 AS "num_batches_fetched",
  "events_processed"::float4 AS "num_events_processed",
  "start_block" AS "start_block",
  "ready_at" AS "timestamp_caught_up_to_head_or_endblock"
FROM "test_schema"."envio_chains";
INSERT INTO "test_schema"."envio_chains" ("id", "ecosystem", "start_block", "end_block", "max_reorg_depth", "source_block", "first_event_block", "buffer_block", "progress_block", "ready_at", "events_processed", "_is_hyper_sync")
VALUES (1, 'evm', 100, 200, 10, 0, NULL, -1, -1, NULL, 0, false),
       (137, 'evm', 0, NULL, 200, 0, NULL, -1, -1, NULL, 0, false);`

        t.expect(mainQuery, ~message="Main query should match expected SQL exactly").toBe(
          expectedMainQuery,
        )
      },
    )

    Async.it(
      "Should handle minimal configuration correctly",
      async t => {
        let queries = PgStorage.makeInitializeTransaction(
          ~pgSchema="test_schema",
          ~pgUser="postgres",
          ~enums=[],
          ~isHasuraEnabled=false,
        )

        t.expect(queries->Array.length, ~message="Should return a single main DDL query").toBe(1)

        let mainQuery = queries->Array.get(0)->Option.getOrThrow

        let expectedMainQuery = `DROP SCHEMA IF EXISTS "test_schema" CASCADE;
CREATE SCHEMA "test_schema";
GRANT ALL ON SCHEMA "test_schema" TO "postgres";
GRANT ALL ON SCHEMA "test_schema" TO public;
CREATE TABLE IF NOT EXISTS "test_schema"."envio_chains"("id" INTEGER NOT NULL, "ecosystem" TEXT NOT NULL, "start_block" INTEGER NOT NULL, "end_block" INTEGER, "max_reorg_depth" INTEGER NOT NULL, "buffer_block" INTEGER NOT NULL, "source_block" INTEGER NOT NULL, "first_event_block" INTEGER, "ready_at" TIMESTAMP WITH TIME ZONE NULL, "events_processed" BIGINT NOT NULL, "_is_hyper_sync" BOOLEAN NOT NULL, "progress_block" INTEGER NOT NULL, PRIMARY KEY("id"));
CREATE TABLE IF NOT EXISTS "test_schema"."envio_info"("id" INTEGER DEFAULT 1, "config" TEXT NOT NULL, PRIMARY KEY("id"));
CREATE TABLE IF NOT EXISTS "test_schema"."envio_contracts"("id" SMALLINT NOT NULL, "name" TEXT NOT NULL, PRIMARY KEY("id"));
CREATE TABLE IF NOT EXISTS "test_schema"."envio_addresses"("chain_id" INTEGER NOT NULL, "address" BYTEA NOT NULL, "contract_id" SMALLINT NOT NULL, "registration_block" INTEGER NOT NULL, PRIMARY KEY("chain_id", "address", "contract_id"));
CREATE TABLE IF NOT EXISTS "test_schema"."envio_checkpoints"("id" BIGINT NOT NULL, "chain_id" INTEGER NOT NULL, "block_number" INTEGER NOT NULL, "block_hash" TEXT, "events_processed" INTEGER NOT NULL, PRIMARY KEY("id"));
CREATE TABLE IF NOT EXISTS "test_schema"."raw_events"("chain_id" INTEGER NOT NULL, "event_id" BIGINT NOT NULL, "event_name" TEXT NOT NULL, "contract_name" TEXT NOT NULL, "block_number" INTEGER NOT NULL, "log_index" INTEGER NOT NULL, "src_address" TEXT NOT NULL, "block_hash" TEXT NOT NULL, "block_timestamp" INTEGER NOT NULL, "block_fields" JSONB NOT NULL, "transaction_fields" JSONB NOT NULL, "params" JSONB NOT NULL, "serial" BIGSERIAL, PRIMARY KEY("serial"));
CREATE VIEW "test_schema"."_meta" AS 
SELECT 
  "id" AS "chainId",
  "ecosystem" AS "ecosystem",
  "start_block" AS "startBlock", 
  "end_block" AS "endBlock",
  "progress_block" AS "progressBlock",
  "buffer_block" AS "bufferBlock",
  "first_event_block" AS "firstEventBlock",
  "events_processed"::float4 AS "eventsProcessed",
  "source_block" AS "sourceBlock",
  "ready_at" AS "readyAt",
  ("ready_at" IS NOT NULL) AS "isReady"
FROM "test_schema"."envio_chains"
ORDER BY "id";
CREATE VIEW "test_schema"."chain_metadata" AS 
SELECT 
  "source_block" AS "block_height",
  "id" AS "chain_id",
  "ecosystem" AS "ecosystem",
  "end_block" AS "end_block", 
  "first_event_block" AS "first_event_block_number",
  "_is_hyper_sync" AS "is_hyper_sync",
  "buffer_block" AS "latest_fetched_block_number",
  "progress_block" AS "latest_processed_block",
  0 AS "num_batches_fetched",
  "events_processed"::float4 AS "num_events_processed",
  "start_block" AS "start_block",
  "ready_at" AS "timestamp_caught_up_to_head_or_endblock"
FROM "test_schema"."envio_chains";`

        t.expect(
          mainQuery,
          ~message="Minimal configuration should match expected SQL exactly",
        ).toBe(expectedMainQuery)
      },
    )

    Async.it(
      "Should create SQL for single entity with indexes",
      async t => {
        // Test with just entity A which has an indexed field
        let entities = [entityConfig("A")]

        let queries = PgStorage.makeInitializeTransaction(
          ~pgSchema="public",
          ~pgUser="postgres",
          ~entities,
          ~enums=[],
          ~isHasuraEnabled=false,
        )

        t.expect(queries->Array.length, ~message="Should return a single main DDL query").toBe(1)

        let mainQuery = queries->Array.get(0)->Option.getOrThrow

        let expectedMainQuery = `DROP SCHEMA IF EXISTS "public" CASCADE;
CREATE SCHEMA "public";
GRANT ALL ON SCHEMA "public" TO "postgres";
GRANT ALL ON SCHEMA "public" TO public;
CREATE TABLE IF NOT EXISTS "public"."envio_chains"("id" INTEGER NOT NULL, "ecosystem" TEXT NOT NULL, "start_block" INTEGER NOT NULL, "end_block" INTEGER, "max_reorg_depth" INTEGER NOT NULL, "buffer_block" INTEGER NOT NULL, "source_block" INTEGER NOT NULL, "first_event_block" INTEGER, "ready_at" TIMESTAMP WITH TIME ZONE NULL, "events_processed" BIGINT NOT NULL, "_is_hyper_sync" BOOLEAN NOT NULL, "progress_block" INTEGER NOT NULL, PRIMARY KEY("id"));
CREATE TABLE IF NOT EXISTS "public"."envio_info"("id" INTEGER DEFAULT 1, "config" TEXT NOT NULL, PRIMARY KEY("id"));
CREATE TABLE IF NOT EXISTS "public"."envio_contracts"("id" SMALLINT NOT NULL, "name" TEXT NOT NULL, PRIMARY KEY("id"));
CREATE TABLE IF NOT EXISTS "public"."envio_addresses"("chain_id" INTEGER NOT NULL, "address" BYTEA NOT NULL, "contract_id" SMALLINT NOT NULL, "registration_block" INTEGER NOT NULL, PRIMARY KEY("chain_id", "address", "contract_id"));
CREATE TABLE IF NOT EXISTS "public"."envio_checkpoints"("id" BIGINT NOT NULL, "chain_id" INTEGER NOT NULL, "block_number" INTEGER NOT NULL, "block_hash" TEXT, "events_processed" INTEGER NOT NULL, PRIMARY KEY("id"));
CREATE TABLE IF NOT EXISTS "public"."raw_events"("chain_id" INTEGER NOT NULL, "event_id" BIGINT NOT NULL, "event_name" TEXT NOT NULL, "contract_name" TEXT NOT NULL, "block_number" INTEGER NOT NULL, "log_index" INTEGER NOT NULL, "src_address" TEXT NOT NULL, "block_hash" TEXT NOT NULL, "block_timestamp" INTEGER NOT NULL, "block_fields" JSONB NOT NULL, "transaction_fields" JSONB NOT NULL, "params" JSONB NOT NULL, "serial" BIGSERIAL, PRIMARY KEY("serial"));
CREATE TABLE IF NOT EXISTS "public"."A"("id" TEXT NOT NULL, "b_id" TEXT NOT NULL, "optionalStringToTestLinkedEntities" TEXT, PRIMARY KEY("id"));
CREATE TABLE IF NOT EXISTS "public"."envio_history_A"("id" TEXT NOT NULL, "b_id" TEXT, "optionalStringToTestLinkedEntities" TEXT, "envio_checkpoint_id" BIGINT NOT NULL, "envio_change" "public".ENVIO_HISTORY_CHANGE NOT NULL, PRIMARY KEY("id", "envio_checkpoint_id"));
CREATE INDEX "${IndexDefinition.single(
            ~tableName="A",
            ~column="b_id",
          )->IndexDefinition.name}" ON "public"."A"("b_id");
CREATE VIEW "public"."_meta" AS 
SELECT 
  "id" AS "chainId",
  "ecosystem" AS "ecosystem",
  "start_block" AS "startBlock", 
  "end_block" AS "endBlock",
  "progress_block" AS "progressBlock",
  "buffer_block" AS "bufferBlock",
  "first_event_block" AS "firstEventBlock",
  "events_processed"::float4 AS "eventsProcessed",
  "source_block" AS "sourceBlock",
  "ready_at" AS "readyAt",
  ("ready_at" IS NOT NULL) AS "isReady"
FROM "public"."envio_chains"
ORDER BY "id";
CREATE VIEW "public"."chain_metadata" AS 
SELECT 
  "source_block" AS "block_height",
  "id" AS "chain_id",
  "ecosystem" AS "ecosystem",
  "end_block" AS "end_block", 
  "first_event_block" AS "first_event_block_number",
  "_is_hyper_sync" AS "is_hyper_sync",
  "buffer_block" AS "latest_fetched_block_number",
  "progress_block" AS "latest_processed_block",
  0 AS "num_batches_fetched",
  "events_processed"::float4 AS "num_events_processed",
  "start_block" AS "start_block",
  "ready_at" AS "timestamp_caught_up_to_head_or_endblock"
FROM "public"."envio_chains";`

        t.expect(mainQuery, ~message="Single entity SQL should match expected output exactly").toBe(
          expectedMainQuery,
        )
      },
    )
  })

  describe("Deferred schema indexes", () => {
    let entities = [entityConfig("A"), entityConfig("B")]

    Async.it(
      "Creates no schema index during the initial DDL, but still the tables and views",
      async t => {
        let mainQuery =
          PgStorage.makeInitializeTransaction(
            ~pgSchema="test_schema",
            ~pgUser="postgres",
            ~entities,
            ~enums=[],
            ~isHasuraEnabled=false,
            ~deferSchemaIndexes=true,
          )
          ->Array.get(0)
          ->Option.getOrThrow

        t.expect(
          (
            mainQuery->String.includes("CREATE INDEX"),
            mainQuery->String.includes(`CREATE TABLE IF NOT EXISTS "test_schema"."A"`),
            mainQuery->String.includes(`PRIMARY KEY("id")`),
            mainQuery->String.includes(`CREATE VIEW "test_schema"."_meta"`),
          ),
          ~message="Schema indexes are absent during backfill; tables, primary keys and views are not",
        ).toEqual((false, true, true, true))
      },
    )

    Async.it(
      "Describes every promised index once, with its generated name",
      async t => {
        let definition = IndexDefinition.single(~tableName="A", ~column="b_id")

        t.expect(
          PgStorage.getSchemaIndexes(~entities)->Array.map(
            definition => (
              definition->IndexDefinition.name,
              definition->IndexDefinition.makeCreateQuery(~pgSchema="test_schema"),
            ),
          ),
          ~message="The @index on A.b and B's derived relationship describe the same index",
        ).toEqual([
          (
            definition->IndexDefinition.name,
            `CREATE INDEX "${definition->IndexDefinition.name}" ON "test_schema"."A"("b_id");`,
          ),
        ])
      },
    )

    // Config parsing rejects a Postgres entity deriving from one that isn't in
    // Postgres, so every `@derivedFrom` target here is guaranteed to resolve.
    Async.it(
      "Emits the index backing a derived relationship on the referenced table",
      async t => {
        let makeEntity = (name, ~fields): Internal.entityConfig => {
          ...entityConfig("A"),
          name,
          table: Table.mkTable(name, ~fields),
          storage: {postgres: true, clickhouse: false},
        }
        let entities = [
          makeEntity(
            "Trader",
            ~fields=[
              Table.mkField("id", String, ~isPrimaryKey=true, ~fieldSchema=S.string),
              Table.mkDerivedFromField(
                "orders",
                ~derivedFromEntity="Order",
                ~derivedFromField="trader",
              ),
            ],
          ),
          makeEntity(
            "Order",
            ~fields=[
              Table.mkField("id", String, ~isPrimaryKey=true, ~fieldSchema=S.string),
              Table.mkField("trader", String, ~linkedEntity="Trader", ~fieldSchema=S.string),
            ],
          ),
        ]

        t.expect(
          PgStorage.getSchemaIndexes(~entities)->Array.map(
            definition => (
              definition.IndexDefinition.tableName,
              definition.columns->Array.map(column => column.IndexDefinition.name),
            ),
          ),
        ).toEqual([("Order", ["trader_id"])])
      },
    )

    // Two long field names on one entity used to truncate to the same
    // 63-character identifier, and the second index silently never got built.
    Async.it(
      "Keeps two long names distinct within Postgres' identifier limit",
      async t => {
        let tableName = "Entity" ++ "x"->String.repeat(50)
        let names =
          ["some_long_column_one", "some_long_column_two"]->Array.map(
            column => IndexDefinition.single(~tableName, ~column)->IndexDefinition.name,
          )

        t.expect((
          names->Array.map(String.length),
          names->Array.getUnsafe(0) === names->Array.getUnsafe(1),
        )).toEqual(([63, 63], false))
      },
    )

    Async.it(
      "Keeps composite index columns ordered with their directions",
      async t => {
        let definition = IndexDefinition.make(
          ~tableName="Transfer",
          ~columns=[
            {name: "block_number", direction: Table.Desc},
            {name: "log_index", direction: Table.Asc},
          ],
        )

        t.expect(definition->IndexDefinition.makeCreateQuery(~pgSchema="s")).toBe(
          `CREATE INDEX "${definition->IndexDefinition.name}" ON "s"."Transfer"("block_number" DESC, "log_index");`,
        )
      },
    )
  })

  describe("makeFilterCondition", () => {
    let table = Table.mkTable(
      "users",
      ~fields=[
        Table.mkField("id", String, ~isPrimaryKey=true, ~fieldSchema=S.string),
        Table.mkField("score", Int32, ~fieldSchema=S.int),
      ],
    )

    Async.it(
      "Should create condition and params for loading multiple records by IDs",
      async t => {
        let params = []
        let condition = PgStorage.makeFilterCondition(
          ~filter=In({
            fieldName: "id",
            fieldValue: ["1", "2"]->(Utils.magic: array<string> => array<unknown>),
          }),
          ~table,
          ~params,
        )

        t.expect((condition, params)).toEqual((
          `"id" = ANY($1)`,
          [["1", "2"]->(Utils.magic: array<string> => JSON.t)],
        ))
      },
    )

    Async.it(
      "Should create condition and params for a scalar comparison",
      async t => {
        let params = []
        let condition = PgStorage.makeFilterCondition(
          ~filter=Gt({fieldName: "score", fieldValue: 5->(Utils.magic: int => unknown)}),
          ~table,
          ~params,
        )

        t.expect((condition, params)).toEqual((`"score" > $1`, [5->(Utils.magic: int => JSON.t)]))
      },
    )

    Async.it(
      "Should number params across nested and filters",
      async t => {
        let params = []
        let condition = PgStorage.makeFilterCondition(
          ~filter=And({
            filters: [
              Eq({fieldName: "id", fieldValue: "1"->(Utils.magic: string => unknown)}),
              And({
                filters: [
                  Gt({fieldName: "score", fieldValue: 5->(Utils.magic: int => unknown)}),
                  Lt({fieldName: "score", fieldValue: 10->(Utils.magic: int => unknown)}),
                ],
              }),
            ],
          }),
          ~table,
          ~params,
        )

        t.expect((condition, params)).toEqual((
          `("id" = $1 AND ("score" > $2 AND "score" < $3))`,
          [
            "1"->(Utils.magic: string => JSON.t),
            5->(Utils.magic: int => JSON.t),
            10->(Utils.magic: int => JSON.t),
          ],
        ))
      },
    )

    Async.it(
      "Should throw a StorageError for an empty and filter",
      async t => {
        let result = try {
          let _ = PgStorage.makeFilterCondition(~filter=And({filters: []}), ~table, ~params=[])
          None
        } catch {
        | Persistence.StorageError({message}) => Some(message)
        }

        t.expect(result).toEqual(
          Some(`Failed loading "users" from storage. The "and" filter must contain at least one nested filter.`),
        )
      },
    )
  })

  describe("makeInsertUnnestSetQuery", () => {
    Async.it(
      "Should create correct SQL for inserting with unnest",
      async t => {
        let query = PgStorage.makeInsertUnnestSetQuery(
          ~pgSchema="test_schema",
          ~table=entityConfig("EntityWithAllNonArrayTypes").table,
          ~itemSchema=entityConfig("EntityWithAllNonArrayTypes").schema,
          ~isRawEvents=false,
        )

        let expectedQuery = `INSERT INTO "test_schema"."EntityWithAllNonArrayTypes" ("id", "string", "optString", "int_", "optInt", "float_", "optFloat", "bool", "optBool", "bigInt", "optBigInt", "bigDecimal", "optBigDecimal", "bigDecimalWithConfig", "enumField", "optEnumField", "timestamp", "optTimestamp")
SELECT * FROM unnest($1::TEXT[],$2::TEXT[],$3::TEXT[],$4::INTEGER[],$5::INTEGER[],$6::DOUBLE PRECISION[],$7::DOUBLE PRECISION[],$8::INTEGER[]::BOOLEAN[],$9::INTEGER[]::BOOLEAN[],$10::NUMERIC[],$11::NUMERIC[],$12::NUMERIC[],$13::NUMERIC[],$14::NUMERIC(10, 8)[],$15::TEXT[]::"test_schema".AccountType[],$16::TEXT[]::"test_schema".AccountType[],$17::TIMESTAMP WITH TIME ZONE[],$18::TIMESTAMP WITH TIME ZONE NULL[])ON CONFLICT("id") DO UPDATE SET "string" = EXCLUDED."string","optString" = EXCLUDED."optString","int_" = EXCLUDED."int_","optInt" = EXCLUDED."optInt","float_" = EXCLUDED."float_","optFloat" = EXCLUDED."optFloat","bool" = EXCLUDED."bool","optBool" = EXCLUDED."optBool","bigInt" = EXCLUDED."bigInt","optBigInt" = EXCLUDED."optBigInt","bigDecimal" = EXCLUDED."bigDecimal","optBigDecimal" = EXCLUDED."optBigDecimal","bigDecimalWithConfig" = EXCLUDED."bigDecimalWithConfig","enumField" = EXCLUDED."enumField","optEnumField" = EXCLUDED."optEnumField","timestamp" = EXCLUDED."timestamp","optTimestamp" = EXCLUDED."optTimestamp";`

        t.expect(query, ~message="Should generate correct unnest insert SQL").toBe(expectedQuery)
      },
    )

    Async.it(
      "Should handle raw events table correctly",
      async t => {
        let query = PgStorage.makeInsertUnnestSetQuery(
          ~pgSchema="test_schema",
          ~table=InternalTable.RawEvents.table,
          ~itemSchema=InternalTable.RawEvents.schema,
          ~isRawEvents=true,
        )

        let expectedQuery = `INSERT INTO "test_schema"."raw_events" ("chain_id", "event_id", "event_name", "contract_name", "block_number", "log_index", "src_address", "block_hash", "block_timestamp", "block_fields", "transaction_fields", "params")
SELECT * FROM unnest($1::INTEGER[],$2::BIGINT[],$3::TEXT[],$4::TEXT[],$5::INTEGER[],$6::INTEGER[],$7::TEXT[],$8::TEXT[],$9::INTEGER[],$10::JSONB[],$11::JSONB[],$12::JSONB[]);`

        t.expect(query, ~message="Don't need EXCLUDED for raw events").toBe(expectedQuery)
      },
    )
  })

  describe("makeInsertValuesSetQuery", () => {
    Async.it(
      "Should create correct SQL for inserting with values",
      async t => {
        let query = PgStorage.makeInsertValuesSetQuery(
          ~pgSchema="test_schema",
          ~table=entityConfig("A").table,
          ~itemSchema=entityConfig("A").schema,
          ~itemsCount=2,
        )

        let expectedQuery = `INSERT INTO "test_schema"."A" ("id", "b_id", "optionalStringToTestLinkedEntities")
VALUES($1,$3,$5),($2,$4,$6)ON CONFLICT("id") DO UPDATE SET "b_id" = EXCLUDED."b_id","optionalStringToTestLinkedEntities" = EXCLUDED."optionalStringToTestLinkedEntities";`

        t.expect(
          query,
          ~message=`Should generate correct values insert SQL.
        The $x in the order, because we flatten unnested entities for the query`,
        ).toBe(expectedQuery)
      },
    )

    Async.it(
      "Should handle table without primary key",
      async t => {
        let query = PgStorage.makeInsertValuesSetQuery(
          ~pgSchema="test_schema",
          ~table=entityConfig("B").table,
          ~itemSchema=entityConfig("B").schema,
          ~itemsCount=1,
        )

        let expectedQuery = `INSERT INTO "test_schema"."B" ("id", "c_id")
VALUES($1,$2)ON CONFLICT("id") DO UPDATE SET "c_id" = EXCLUDED."c_id";`

        t.expect(
          query,
          ~message="Should generate correct values insert SQL for table without primary key",
        ).toBe(expectedQuery)
      },
    )
  })

  describe("InternalTable.Chains.makeMetaFieldsUpdateQuery", () => {
    Async.it(
      "Should create correct SQL for updating chain state",
      async t => {
        let query = InternalTable.Chains.makeMetaFieldsUpdateQuery(~pgSchema="test_schema")

        let expectedQuery = `UPDATE "test_schema"."envio_chains"
SET "buffer_block" = $2,
    "first_event_block" = $3,
    "ready_at" = $4,
    "_is_hyper_sync" = $5
WHERE "id" = $1;`

        t.expect(
          query,
          ~message="Should generate correct UPDATE SQL with parameter placeholders",
        ).toBe(expectedQuery)
      },
    )
  })

  describe("InternalTable.Chains.makeProgressFieldsUpdateQuery", () => {
    Async.it(
      "Should create correct SQL for updating chain progress fields",
      async t => {
        let query = InternalTable.Chains.makeProgressFieldsUpdateQuery(~pgSchema="test_schema")

        let expectedQuery = `UPDATE "test_schema"."envio_chains"
SET "progress_block" = $2,
    "events_processed" = $3,
    "source_block" = $4
WHERE "id" = $1;`

        t.expect(
          query,
          ~message="Should generate correct UPDATE SQL for progress fields with parameter placeholders",
        ).toBe(expectedQuery)
      },
    )
  })

  describe("InternalTable.Checkpoints.makeGetReorgCheckpointsQuery", () => {
    Async.it(
      "Should generate optimized SQL query with CTE",
      async t => {
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
  AND cp."block_number" >= rc.safe_block
ORDER BY cp."id";`

        t.expect(
          query,
          ~message="Should generate optimized CTE query filtering chains outside reorg threshold",
        ).toBe(expectedQuery)
      },
    )
  })

  describe("InternalTable.Chains.makeInitialValuesQuery", () => {
    Async.it(
      "Should return empty string for empty chain configs",
      async t => {
        let query = InternalTable.Chains.makeInitialValuesQuery(
          ~pgSchema="test_schema",
          ~chainConfigs=[],
        )

        t.expect(query, ~message="Should return empty string when no chain configs provided").toBe(
          None,
        )
      },
    )

    Async.it(
      "Should create correct SQL for single chain config",
      async t => {
        let chainConfig: Config.chain = {
          name: "Chain1",
          id: 1->ChainId.fromInt,
          ecosystem: Ecosystem.Evm,
          startBlock: 100,
          endBlock: 200,
          maxReorgDepth: 5,
          blockLag: 0,
          contracts: [],
          sourceConfig: Config.CustomSources([]),
        }

        let query = InternalTable.Chains.makeInitialValuesQuery(
          ~pgSchema="test_schema",
          ~chainConfigs=[chainConfig],
        )

        let expectedQuery = `INSERT INTO "test_schema"."envio_chains" ("id", "ecosystem", "start_block", "end_block", "max_reorg_depth", "source_block", "first_event_block", "buffer_block", "progress_block", "ready_at", "events_processed", "_is_hyper_sync")
VALUES (1, 'evm', 100, 200, 5, 0, NULL, -1, -1, NULL, 0, false);`

        t.expect(query, ~message="Should generate correct INSERT VALUES SQL for single chain").toBe(
          Some(expectedQuery),
        )
      },
    )

    Async.it(
      "Should create correct SQL for single chain config with no end block",
      async t => {
        let chainConfig: Config.chain = {
          name: "Chain1",
          id: 1->ChainId.fromInt,
          ecosystem: Ecosystem.Evm,
          startBlock: 100,
          maxReorgDepth: 5,
          blockLag: 0,
          contracts: [],
          sourceConfig: Config.CustomSources([]),
        }

        let query = InternalTable.Chains.makeInitialValuesQuery(
          ~pgSchema="public",
          ~chainConfigs=[chainConfig],
        )

        let expectedQuery = `INSERT INTO "public"."envio_chains" ("id", "ecosystem", "start_block", "end_block", "max_reorg_depth", "source_block", "first_event_block", "buffer_block", "progress_block", "ready_at", "events_processed", "_is_hyper_sync")
VALUES (1, 'evm', 100, NULL, 5, 0, NULL, -1, -1, NULL, 0, false);`

        t.expect(
          query,
          ~message="Should generate correct INSERT VALUES SQL with NULL end_block",
        ).toBe(Some(expectedQuery))
      },
    )

    Async.it(
      "Should create correct SQL for multiple chain configs",
      async t => {
        let chainConfig1: Config.chain = {
          name: "Chain1",
          id: 1->ChainId.fromInt,
          ecosystem: Ecosystem.Evm,
          startBlock: 100,
          endBlock: 200,
          maxReorgDepth: 5,
          blockLag: 0,
          contracts: [],
          sourceConfig: Config.CustomSources([]),
        }

        let chainConfig2: Config.chain = {
          name: "Chain42",
          id: 42->ChainId.fromInt,
          ecosystem: Ecosystem.Evm,
          startBlock: 500,
          maxReorgDepth: 0,
          blockLag: 0,
          contracts: [],
          sourceConfig: Config.CustomSources([]),
        }

        let query = InternalTable.Chains.makeInitialValuesQuery(
          ~pgSchema="production",
          ~chainConfigs=[chainConfig1, chainConfig2],
        )

        let expectedQuery = `INSERT INTO "production"."envio_chains" ("id", "ecosystem", "start_block", "end_block", "max_reorg_depth", "source_block", "first_event_block", "buffer_block", "progress_block", "ready_at", "events_processed", "_is_hyper_sync")
VALUES (1, 'evm', 100, 200, 5, 0, NULL, -1, -1, NULL, 0, false),
       (42, 'evm', 500, NULL, 0, 0, NULL, -1, -1, NULL, 0, false);`

        t.expect(
          query,
          ~message="Should generate correct INSERT VALUES SQL for multiple chains",
        ).toBe(Some(expectedQuery))
      },
    )
  })

  describe("InternalTable.Chains.makeGetInitialStateQuery", () => {
    Async.it(
      "Should create correct SQL for initial state query",
      async t => {
        let query = InternalTable.Chains.makeGetInitialStateQuery(~pgSchema="test_schema")

        let expectedQuery = `SELECT "id" as "id",
"start_block" as "startBlock",
"end_block" as "endBlock",
"max_reorg_depth" as "maxReorgDepth",
"first_event_block" as "firstEventBlockNumber",
"ready_at" as "timestampCaughtUpToHeadOrEndblock",
"events_processed"::float8 as "numEventsProcessed",
"progress_block" as "progressBlockNumber",
"source_block" as "sourceBlockNumber"
FROM "test_schema"."envio_chains";`

        t.expect(query, ~message="Initial state SQL should match exactly").toBe(expectedQuery)
      },
    )
  })

  describe("InternalTable.EnvioAddresses.makeGetRowsQuery", () => {
    Async.it(
      "Should create correct SQL for indexing addresses query",
      async t => {
        let query = InternalTable.EnvioAddresses.makeGetRowsQuery(~pgSchema="test_schema")

        let expectedQuery = `SELECT "chain_id" as "chainId",
"address" as "address",
"contract_id" as "contractId",
"registration_block" as "registrationBlock"
FROM "test_schema"."envio_addresses";`

        t.expect(query, ~message="Indexing addresses SQL should match exactly").toBe(expectedQuery)
      },
    )
  })

  describe("InternalTable.Checkpoints.makeCommitedCheckpointIdQuery", () => {
    Async.it(
      "Should create correct SQL to get committed checkpoint id",
      async t => {
        let query = InternalTable.Checkpoints.makeCommitedCheckpointIdQuery(~pgSchema="test_schema")

        t.expect(
          query,
          ~message="Committed checkpoint id SQL should match exactly",
        ).toBe(`SELECT COALESCE(MAX(id), 0) AS id FROM "test_schema"."envio_checkpoints";`)
      },
    )
  })

  describe("InternalTable.Checkpoints.makeInsertCheckpointQuery", () => {
    Async.it(
      "Should create correct SQL for inserting checkpoints with unnest",
      async t => {
        let query = InternalTable.Checkpoints.makeInsertCheckpointQuery(~pgSchema="test_schema")

        let expectedQuery = `INSERT INTO "test_schema"."envio_checkpoints" ("id", "chain_id", "block_number", "block_hash", "events_processed")
SELECT * FROM unnest($1::BIGINT[],$2::INTEGER[],$3::INTEGER[],$4::TEXT[],$5::INTEGER[]);`

        t.expect(query, ~message="Insert checkpoints SQL should match exactly").toBe(expectedQuery)
      },
    )
  })

  describe("InternalTable.Checkpoints.makePruneStaleCheckpointsQuery", () => {
    Async.it(
      "Should create correct SQL for pruning stale checkpoints",
      async t => {
        let query = InternalTable.Checkpoints.makePruneStaleCheckpointsQuery(
          ~pgSchema="test_schema",
        )

        t.expect(
          query,
          ~message="Prune stale checkpoints SQL should match exactly",
        ).toBe(`DELETE FROM "test_schema"."envio_checkpoints" WHERE "id" < $1;`)
      },
    )
  })

  describe("InternalTable.Checkpoints.makeGetRollbackTargetCheckpointQuery", () => {
    Async.it(
      "Should create correct SQL for rollback target checkpoint",
      async t => {
        let query = InternalTable.Checkpoints.makeGetRollbackTargetCheckpointQuery(
          ~pgSchema="test_schema",
        )

        let expectedQuery = `SELECT "id" FROM "test_schema"."envio_checkpoints"
WHERE 
  "chain_id" = $1 AND
  "block_number" <= $2
ORDER BY "id" DESC
LIMIT 1;`

        t.expect(query, ~message="Rollback target checkpoint SQL should match exactly").toBe(
          expectedQuery,
        )
      },
    )
  })

  describe("InternalTable.Checkpoints.makeGetRollbackProgressDiffQuery", () => {
    Async.it(
      "Should create correct SQL for rollback progress diff",
      async t => {
        let query = InternalTable.Checkpoints.makeGetRollbackProgressDiffQuery(
          ~pgSchema="test_schema",
          ~scope=Global,
        )

        let expectedQuery = `SELECT 
  "chain_id"::float8 as "chain_id",
  SUM("events_processed") as events_processed_diff,
  MIN("block_number") - 1 as new_progress_block_number
FROM "test_schema"."envio_checkpoints"
WHERE "id" > $1
GROUP BY "chain_id";`

        t.expect(query, ~message="Rollback progress diff SQL should match exactly").toBe(
          expectedQuery,
        )
      },
    )
  })
})

// Runs the validation path in makeStorageFromEnv taken only when
// `storage.clickhouse: true` in config.yaml. The vars are cleared around the
// call rather than assumed absent: the scenario's own ClickHouse tests need them
// set, so an ambient value would leave nothing missing to report.
let withoutClickHouseEnv = fn => {
  let names = [
    "ENVIO_CLICKHOUSE_HOST",
    "ENVIO_CLICKHOUSE_USERNAME",
    "ENVIO_CLICKHOUSE_PASSWORD",
    "ENVIO_CLICKHOUSE_DATABASE",
  ]
  let env = NodeJs.Process.process.env
  let saved = names->Array.map(name => (name, env->Utils.Dict.dangerouslyGetNonOption(name)))
  names->Array.forEach(name => env->Dict.delete(name))
  let result = try Ok(fn()) catch {
  | exn => Error(exn)
  }
  saved->Array.forEach(((name, value)) =>
    switch value {
    | Some(value) => env->Dict.set(name, value)
    | None => ()
    }
  )
  switch result {
  | Ok(value) => value
  | Error(exn) => throw(exn)
  }
}

describe("PgStorage.makeStorageFromEnv ClickHouse env var validation", () => {
  Async.it(
    "Throws listing all missing ENVIO_CLICKHOUSE_* env vars when storage.clickhouse=true",
    async t => {
      let config = {
        ...config,
        storage: (
          {
            postgres: true,
            clickhouse: true,
            postgresColumnNameFormat: Original,
            clickhouseColumnNameFormat: Original,
          }: Config.storage
        ),
      }
      let message = withoutClickHouseEnv(
        () =>
          switch try {
            let _ = PgStorage.makeStorageFromEnv(~config)
            None
          } catch {
          | JsExn(e) => Some(e->JsExn.message->Option.getOr(""))
          | _ => None
          } {
          | Some(m) => m
          | None => ""
          },
      )
      t.expect(
        message,
        ~message="Should throw a helpful error naming every missing env var at once",
      ).toBe(
        "ClickHouse storage is enabled but required env vars are not set: ENVIO_CLICKHOUSE_HOST, ENVIO_CLICKHOUSE_USERNAME, ENVIO_CLICKHOUSE_PASSWORD, ENVIO_CLICKHOUSE_DATABASE. Please set them, disable clickhouse in the `storage` config, or run `envio dev` for a pre-configured local ClickHouse.",
      )
    },
  )

  Async.it("Does not throw when storage.clickhouse=false (default)", async t => {
    let config = {
      ...config,
      storage: (
        {
          postgres: true,
          clickhouse: false,
          postgresColumnNameFormat: Original,
          clickhouseColumnNameFormat: Original,
        }: Config.storage
      ),
    }
    // Just ensure construction succeeds without touching ClickHouse env vars.
    let _ = PgStorage.makeStorageFromEnv(~config)
    t.expect(true, ~message="Expected no throw when clickhouse is disabled").toBe(true)
  })

  // `envio dev` applies ENVIO_CLICKHOUSE_* vars via Bin.applyEnv, which runs
  // AFTER Env.res has been imported. If Env.ClickHouse cached reads at module
  // load, those late writes would be invisible and validation would still
  // throw. This test simulates that timing by writing the vars to process.env
  // right before calling makeStorageFromEnv.
  Async.it("Picks up ENVIO_CLICKHOUSE_* vars set after Env.res has been loaded", async t => {
    let getEnvVar: string => option<string> = %raw(`(k) => process.env[k]`)
    let setEnvVar: (string, string) => unit = %raw(`(k, v) => { process.env[k] = v; }`)
    let unsetEnvVar: string => unit = %raw(`(k) => { delete process.env[k]; }`)
    // The ClickHouse leg points the process at its own database through these
    // same vars, so deleting them unconditionally would strip the run's wiring
    // from every test after this one in the file.
    let restored = [
      ("ENVIO_CLICKHOUSE_HOST", "http://localhost:8123"),
      ("ENVIO_CLICKHOUSE_USERNAME", "default"),
      ("ENVIO_CLICKHOUSE_PASSWORD", "testing"),
      ("ENVIO_CLICKHOUSE_DATABASE", "envio_indexer"),
    ]->Array.map(
      ((key, value)) => {
        let before = getEnvVar(key)
        setEnvVar(key, value)
        (key, before)
      },
    )
    let config = {
      ...config,
      storage: (
        {
          postgres: true,
          clickhouse: true,
          postgresColumnNameFormat: Original,
          clickhouseColumnNameFormat: Original,
        }: Config.storage
      ),
    }
    let result = try {
      let _ = PgStorage.makeStorageFromEnv(~config)
      Ok()
    } catch {
    | JsExn(e) => Error(e->JsExn.message->Option.getOr(""))
    | _ => Error("non-JsExn")
    }
    restored->Array.forEach(
      ((key, before)) =>
        switch before {
        | Some(value) => setEnvVar(key, value)
        | None => unsetEnvVar(key)
        },
    )
    t.expect(
      result,
      ~message="Should read ClickHouse env vars lazily so envio dev's late injection works",
    ).toEqual(Ok())
  })
})

describe("ecosystem.toRawEvent", () => {
  Async.it(
    "Derives a raw event row from a batch item, taking block hash and timestamp from the payload block and stringifying bigint block fields",
    async t => {
      let srcAddress =
        "0x00000000000000000000000000000000000000ab"->(Utils.magic: string => Address.t)
      let blockNumber = 5
      let logIndex = 3

      let event = {
        "block": %raw(`{"number": 5, "timestamp": 9999, "hash": "0xblockhash", "gasUsed": 99n, "miner": "0xminer"}`),
        "transaction": %raw(`{"hash": "0xtxhash", "transactionIndex": 2}`),
        "params": (),
        "logIndex": logIndex,
        "srcAddress": srcAddress,
        "chainId": 137,
        "contractName": "ERC20",
        "eventName": "EventWithoutFields",
      }->(
        Utils.magic: {
          "block": JSON.t,
          "transaction": JSON.t,
          "params": unit,
          "logIndex": int,
          "srcAddress": Address.t,
          "chainId": int,
          "contractName": string,
          "eventName": string,
        } => Internal.eventPayload
      )

      let eventItem = Internal.Event({
        onEventRegistration: (EventRegistration.evmOnEventRegistration(
          ~contractName="ERC20",
        ) :> Internal.onEventRegistration),
        chainId: 137->ChainId.fromInt,
        blockNumber,
        logIndex,
        transactionIndex: 0,
        payload: event,
      })->Internal.castUnsafeEventItem

      t.expect(ecosystem.toRawEvent(eventItem)).toEqual({
        chain_id: 137->ChainId.fromInt,
        event_id: EventUtils.packEventIndex(~logIndex, ~blockNumber),
        event_name: "EventWithoutFields",
        contract_name: "ERC20",
        block_number: blockNumber,
        log_index: logIndex,
        src_address: srcAddress,
        block_hash: "0xblockhash",
        block_timestamp: 9999,
        block_fields: %raw(`{"gasUsed": "99", "miner": "0xminer"}`),
        transaction_fields: %raw(`{"hash": "0xtxhash", "transactionIndex": 2}`),
        params: %raw(`"null"`),
      })
    },
  )
})

describe("PgStorage.removeInvalidUtf8InPlace", () => {
  Async.it(
    "Strips NUL bytes from raw event rows, including deep inside jsonb params and field selections",
    async t => {
      let rawEvent: InternalTable.RawEvents.t = {
        chain_id: 1->ChainId.fromInt,
        event_id: 42n,
        event_name: "Name\x00Changed",
        contract_name: "Resolver",
        block_number: 5,
        log_index: 3,
        src_address: "0x00000000000000000000000000000000000000ab"->(
          Utils.magic: string => Address.t
        ),
        block_hash: "0xhash",
        block_timestamp: 100,
        block_fields: %raw(`{"extraData": "0x00\x00ff"}`),
        transaction_fields: %raw(`{"hash": "0xtx"}`),
        params: %raw(`{"node": "0xnode", "name": "Muscle-window.eth\x00tail", "labels": ["a\x00b", "c"]}`),
      }

      [rawEvent]->PgStorage.removeInvalidUtf8InPlace

      t.expect(rawEvent).toEqual({
        chain_id: 1->ChainId.fromInt,
        event_id: 42n,
        event_name: "NameChanged",
        contract_name: "Resolver",
        block_number: 5,
        log_index: 3,
        src_address: "0x00000000000000000000000000000000000000ab"->(
          Utils.magic: string => Address.t
        ),
        block_hash: "0xhash",
        block_timestamp: 100,
        block_fields: %raw(`{"extraData": "0x00ff"}`),
        transaction_fields: %raw(`{"hash": "0xtx"}`),
        params: %raw(`{"node": "0xnode", "name": "Muscle-window.ethtail", "labels": ["ab", "c"]}`),
      })
    },
  )
})
