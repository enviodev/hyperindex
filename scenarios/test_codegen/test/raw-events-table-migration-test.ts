import { mockRawEventRow } from "./helpers/Mock.gen";
import { runMigrationsNoLogs, createSql, EventVariants } from "./helpers/utils";
import chai, { expect } from "chai";
import chaiAsPromised from "chai-as-promised";

// require("mocha-reporter").hook(); //Outputs filename in error logs with mocha-reporter
chai.use(chaiAsPromised);

describe("Raw Events Table Migrations", () => {
  const sql = createSql();

  before(async () => {
    await runMigrationsNoLogs();
  });
  after(async () => {
    await runMigrationsNoLogs();
  });

  it("Raw events table should migrate successfully", async () => {
    let rawEventsColumnsRes = await sql`
      SELECT COLUMN_NAME, DATA_TYPE
      FROM INFORMATION_SCHEMA.COLUMNS
      WHERE TABLE_NAME = 'raw_events';
    `;

    let expectedColumns = [
      { column_name: "chain_id", data_type: "integer" },
      { column_name: "event_id", data_type: "numeric" },
      { column_name: "block_number", data_type: "integer" },
      { column_name: "log_index", data_type: "integer" },
      { column_name: "block_timestamp", data_type: "integer" },
      { column_name: "params", data_type: "jsonb" },
      { column_name: "block_hash", data_type: "text" },
      { column_name: "block_fields", data_type: "jsonb" },
      { column_name: "transaction_fields", data_type: "jsonb" },
      { column_name: "src_address", data_type: "text" },
    ];

    expect(rawEventsColumnsRes).to.deep.include.members(expectedColumns);
  });

  //Since the rework of rollbacks in v2.8, rollbacks are not supported for raw events
  //Duplicates are allowed to stop inserts breaking on rollbacks. If these need to be handled
  //in the future, raw events can be converted into an entity (with managed history) like dynamic
  //contracts.
  it("Inserting 2 rows with the the same pk should pass", async () => {
    let first_valid_row_query = sql`INSERT INTO raw_events ${sql(
      mockRawEventRow as any
    )}`;

    await expect(first_valid_row_query).to.eventually.be.fulfilled;

    let second_valid_row_query = sql`INSERT INTO raw_events ${sql(
      mockRawEventRow as any
    )}`;

    await expect(second_valid_row_query).to.eventually.be.fulfilled;
  });
});
