import { runMigrationsNoLogs, createSql } from "./helpers/utils";
import chai, { expect } from "chai";
import chaiAsPromised from "chai-as-promised";

// Enable Chai plugins
chai.use(chaiAsPromised);

describe("Postgres Numeric Precision Entity Tester Migrations", () => {
  const sql = createSql();

  before(async () => {
    // Run migrations to set up the database
    await runMigrationsNoLogs();
  });

  after(async () => {
    // Optionally, run migrations again to reset the database
    await runMigrationsNoLogs();
  });

  it("should have the correct columns and data types in 'PostgresNumericPrecisionEntityTester' table", async () => {
    //  This SQL is quite a beast, but it does work 🙏
    const columnsRes = await sql`
      SELECT
        a.attname AS column_name,
        pg_catalog.format_type(a.atttypid, a.atttypmod) AS data_type,
        CASE
          WHEN t.typcategory = 'A' THEN
            pg_catalog.format_type(t.typelem, NULL)
          ELSE ''
        END AS element_data_type,
        CASE
          WHEN t.typname LIKE 'numeric%' OR et.typname LIKE 'numeric%' THEN
            (regexp_match(pg_catalog.format_type(a.atttypid, a.atttypmod), 'numeric\\((\\d+),(\\d+)\\)'))[1]::int
          ELSE NULL
        END AS numeric_precision,
        CASE
          WHEN t.typname LIKE 'numeric%' OR et.typname LIKE 'numeric%' THEN
            (regexp_match(pg_catalog.format_type(a.atttypid, a.atttypmod), 'numeric\\((\\d+),(\\d+)\\)'))[2]::int
          ELSE NULL
        END AS numeric_scale,
        CASE
          WHEN a.attnotnull THEN 'NO'
          ELSE 'YES'
        END AS is_nullable,
        pg_get_expr(d.adbin, d.adrelid) AS column_default
      FROM
        pg_attribute a
        JOIN pg_class c ON a.attrelid = c.oid
        JOIN pg_namespace n ON c.relnamespace = n.oid
        JOIN pg_type t ON a.atttypid = t.oid
        LEFT JOIN pg_type et ON t.typelem = et.oid
        LEFT JOIN pg_attrdef d ON a.attrelid = d.adrelid AND a.attnum = d.adnum
      WHERE
        n.nspname = 'public' AND
        c.relname = 'PostgresNumericPrecisionEntityTester' AND
        a.attnum > 0 AND
        NOT a.attisdropped
      ORDER BY
        a.attnum;
    `;

    // Define the expected columns and their properties
    const expectedColumns = [
      {
        column_name: "id",
        data_type: "text",
        numeric_precision: null,
        numeric_scale: null,
        is_nullable: "NO",
      },
      {
        column_name: "exampleBigInt",
        data_type: "numeric(76,0)",
        numeric_precision: 76,
        numeric_scale: 0,
        is_nullable: "YES",
      },
      {
        column_name: "exampleBigIntRequired",
        data_type: "numeric(77,0)",
        numeric_precision: 77,
        numeric_scale: 0,
        is_nullable: "NO",
      },
      {
        column_name: "exampleBigIntArray",
        data_type: "numeric(78,0)[]",
        element_data_type: "numeric",
        numeric_precision: 78,
        numeric_scale: 0,
        is_nullable: "YES",
      },
      {
        column_name: "exampleBigIntArrayRequired",
        data_type: "numeric(79,0)[]",
        element_data_type: "numeric",
        numeric_precision: 79,
        numeric_scale: 0,
        is_nullable: "NO",
      },
      {
        column_name: "exampleBigDecimal",
        data_type: "numeric(80,5)",
        numeric_precision: 80,
        numeric_scale: 5,
        is_nullable: "YES",
      },
      {
        column_name: "exampleBigDecimalRequired",
        data_type: "numeric(81,5)",
        numeric_precision: 81,
        numeric_scale: 5,
        is_nullable: "NO",
      },
      {
        column_name: "exampleBigDecimalArray",
        data_type: "numeric(82,5)[]",
        element_data_type: "numeric",
        numeric_precision: 82,
        numeric_scale: 5,
        is_nullable: "YES",
      },
      {
        column_name: "exampleBigDecimalArrayRequired",
        data_type: "numeric(83,5)[]",
        element_data_type: "numeric",
        numeric_precision: 83,
        numeric_scale: 5,
        is_nullable: "NO",
      },
      {
        column_name: "exampleBigDecimalOtherOrder",
        data_type: "numeric(84,6)",
        numeric_precision: 84,
        numeric_scale: 6,
        is_nullable: "NO",
      },
    ];

    // Map the query results to a simplified format for comparison
    const actualColumns = columnsRes.map((row: any) => ({
      column_name: row.column_name,
      data_type: row.data_type,
      element_data_type: row.element_data_type,
      numeric_precision: row.numeric_precision,
      numeric_scale: row.numeric_scale,
      is_nullable: row.is_nullable,
    }));

    // Check that all expected columns are present with correct properties
    expectedColumns.forEach((expectedColumn) => {
      const actualColumn = actualColumns.find(
        (col: any) => col.column_name === expectedColumn.column_name
      );
      expect(actualColumn).to.exist;
      expect(actualColumn).to.deep.include(expectedColumn);
    });

    // Check that there are no extra columns
    expect(actualColumns.length).to.equal(expectedColumns.length + 1 /*  We need to add one since the db_write_timestamp is added automatically. */);
  });
});
