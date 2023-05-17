import {
  runDownMigrations,
  runUpMigrations,
} from "../generated/src/Migrations.bs";
import { runMigrationsNoLogs, sql } from "./helpers/utils";
import chai, { expect } from "chai";
import chaiAsPromised from "chai-as-promised";

require("mocha-reporter").hook(); //Outputs filename in error logs with mocha-reporter
chai.use(chaiAsPromised);

describe("Raw Events Table Migrations", () => {
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
      { column_name: "transaction_index", data_type: "integer" },
      { column_name: "block_timestamp", data_type: "integer" },
      { column_name: "params", data_type: "json" },
      { column_name: "block_hash", data_type: "text" },
      { column_name: "transaction_hash", data_type: "text" },
      { column_name: "src_address", data_type: "text" },
    ];

    expect(rawEventsColumnsRes).to.deep.include.members(expectedColumns);
  });

  it("Inserting 2 rows with the the same pk should fail", async () => {
    const mockRow = {
      chain_id: 1,
      event_id: 1234567890,
      block_number: 1000,
      log_index: 10,
      transaction_index: 20,
      transaction_hash: "0x1234567890abcdef",
      src_address: "0x0123456789abcdef0123456789abcdef0123456",
      block_hash: "0x9876543210fedcba9876543210fedcba987654321",
      block_timestamp: 1620720000,
      params: {
        foo: "bar",
        baz: 42,
      },
    };
    let first_valid_row_query = sql`INSERT INTO raw_events ${sql(mockRow)}`;

    await expect(first_valid_row_query).to.eventually.be.fulfilled;

    let second_valid_row_query = sql`INSERT INTO raw_events ${sql(mockRow)}`;

    await expect(second_valid_row_query).to.eventually.be.rejected;
  });
});
