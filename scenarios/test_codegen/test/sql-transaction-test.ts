import chai, { expect } from "chai";
import { mockRawEventRow } from "./helpers/Mocks.gen";
import { runMigrationsNoLogs, createSql, EventVariants } from "./helpers/utils";

import chaiAsPromised from "chai-as-promised";
chai.use(chaiAsPromised);
// require("mocha-reporter").hook(); //Outputs filename in error logs with mocha-reporter
describe("Sql transaction tests", () => {
  const sql = createSql();

  beforeEach(async () => {
    await runMigrationsNoLogs();
  });
  after(async () => {
    await runMigrationsNoLogs();
  });

  it("3 raw events set as transaction", async () => {
    const mockRawEventRow2 = {
      ...mockRawEventRow,
      event_id: mockRawEventRow.event_id + 1,
    };
    const mockRawEventRow3 = {
      ...mockRawEventRow,
      event_id: mockRawEventRow.event_id + 2,
    };

    const transaction = sql.begin((sql) => [
      sql`INSERT INTO raw_events ${sql(mockRawEventRow as any)}`,
      sql`INSERT INTO raw_events ${sql(mockRawEventRow2 as any)}`,
      sql`INSERT INTO raw_events ${sql(mockRawEventRow3 as any)}`,
    ]);

    await expect(transaction).to.eventually.be.fulfilled;

    let rawEventsRows = await sql`SELECT * FROM public.raw_events`;
    expect(rawEventsRows.count).to.be.eq(3);
  });

  it("3 raw events set with one invalid fails", async () => {
    const mockRawEventRow2 = {
      ...mockRawEventRow,
      event_id: mockRawEventRow.event_id + 1,
    };
    const mockRawEventRow3 = {
      ...mockRawEventRow,
      event_id: mockRawEventRow.event_id + 2,
      event_key: "INVALID_EVENT_TYPE",
    };
    const transaction = sql.begin((sql) => [
      sql`INSERT INTO raw_events ${sql(mockRawEventRow as any)}`,
      sql`INSERT INTO raw_events ${sql(mockRawEventRow2 as any)}`,
      sql`INSERT INTO raw_events ${sql(mockRawEventRow3 as any)}`,
    ]);

    await expect(transaction).to.eventually.be.rejected;

    let rawEventsRows = await sql`SELECT * FROM public.raw_events`;
    expect(rawEventsRows.count).to.be.eq(0);
  });
});
