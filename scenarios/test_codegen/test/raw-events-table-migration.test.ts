import { mockRawEventRow } from "./helpers/Mock.gen";
import { runMigrationsNoLogs, createSql, EventVariants } from "./helpers/utils";
import { describe, it, expect, beforeAll, afterAll } from "vitest";

function insertRawEvent(sql: any, row: any) {
  const columns = Object.keys(row);
  const values = Object.values(row);
  const placeholders = columns.map((_, i) => `$${i + 1}`).join(", ");
  const columnNames = columns.map((c) => `"${c}"`).join(", ");
  return sql.query({
    name: "insert_raw_events",
    text: `INSERT INTO raw_events (${columnNames}) VALUES (${placeholders})`,
    values,
  });
}

describe("Raw Events Table Migrations", () => {
  const sql = createSql();

  beforeAll(async () => {
    await runMigrationsNoLogs();
  });
  afterAll(async () => {
    await runMigrationsNoLogs();
  });

  it("Raw events table should migrate successfully", async () => {
    let { rows: rawEventsColumnsRes } = await sql.query(`
      SELECT COLUMN_NAME, DATA_TYPE
      FROM INFORMATION_SCHEMA.COLUMNS
      WHERE TABLE_NAME = 'raw_events';
    `);

    let expectedColumns = [
      { column_name: "chain_id", data_type: "integer" },
      { column_name: "event_id", data_type: "bigint" },
      { column_name: "block_number", data_type: "integer" },
      { column_name: "log_index", data_type: "integer" },
      { column_name: "block_timestamp", data_type: "integer" },
      { column_name: "params", data_type: "jsonb" },
      { column_name: "block_hash", data_type: "text" },
      { column_name: "block_fields", data_type: "jsonb" },
      { column_name: "transaction_fields", data_type: "jsonb" },
      { column_name: "src_address", data_type: "text" },
      { column_name: "serial", data_type: "bigint" },
    ];

    expect(rawEventsColumnsRes).toEqual(
      expect.arrayContaining(
        expectedColumns.map((col) => expect.objectContaining(col))
      )
    );
  });

  //Since the rework of rollbacks in v2.8, rollbacks are not supported for raw events
  //Duplicates are allowed to stop inserts breaking on rollbacks. If these need to be handled
  //in the future, raw events can be converted into an entity (with managed history) like dynamic
  //contracts.
  it("Inserting 2 rows with the the same pk should pass", async () => {
    let first_valid_row_query = insertRawEvent(sql, mockRawEventRow);

    await expect(first_valid_row_query).resolves.toBeDefined();

    let second_valid_row_query = insertRawEvent(sql, mockRawEventRow);

    await expect(second_valid_row_query).resolves.toBeDefined();
  });
});
