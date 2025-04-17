open Table
open RescriptMocha

let isPrimaryKey = true

describe("Table functions postgres interop", () => {
  it("Makes batch set function for entity", () => {
    let table = mkTable(
      "test_table",
      ~schemaName="public",
      ~fields=[
        mkField("id", Text, ~fieldSchema=S.string, ~isPrimaryKey),
        mkField("field_a", Numeric, ~fieldSchema=S.bigint),
      ],
    )

    let batchSetFnString = table->PostgresInterop.makeBatchSetFnString

    let expected = `(sql, rows) => {
      return sql\`
        INSERT INTO "public"."test_table"
        \${sql(rows, "id", "field_a")}
        ON CONFLICT(id) DO UPDATE
        SET
        "id" = EXCLUDED."id", "field_a" = EXCLUDED."field_a";\`
    }`

    Assert.equal(batchSetFnString, expected)
  })

  it("Makes batch set function for entity with custom schema", () => {
    let table = mkTable(
      "test_table",
      ~schemaName="custom",
      ~fields=[
        mkField("id", Text, ~fieldSchema=S.string, ~isPrimaryKey),
        mkField("field_a", ~fieldSchema=S.bigint, Numeric),
      ],
    )

    let batchSetFnString = table->PostgresInterop.makeBatchSetFnString

    let expected = `(sql, rows) => {
      return sql\`
        INSERT INTO "custom"."test_table"
        \${sql(rows, "id", "field_a")}
        ON CONFLICT(id) DO UPDATE
        SET
        "id" = EXCLUDED."id", "field_a" = EXCLUDED."field_a";\`
    }`

    Assert.equal(batchSetFnString, expected)
  })

  it("Makes batch set function for table with multiple primary keys", () => {
    let table = mkTable(
      "test_table",
      ~schemaName="public",
      ~fields=[
        mkField("field_a", Integer, ~fieldSchema=S.bigint, ~isPrimaryKey=true),
        mkField("field_b", Integer, ~fieldSchema=S.bigint, ~isPrimaryKey=true),
        mkField("field_c", Text, ~fieldSchema=S.string),
      ],
    )

    let batchSetFnString = table->PostgresInterop.makeBatchSetFnString

    let expected = `(sql, rows) => {
      return sql\`
        INSERT INTO "public"."test_table"
        \${sql(rows, "field_a", "field_b", "field_c")}
        ON CONFLICT(field_a, field_b) DO UPDATE
        SET
        "field_a" = EXCLUDED."field_a", "field_b" = EXCLUDED."field_b", "field_c" = EXCLUDED."field_c";\`
    }`

    Assert.equal(batchSetFnString, expected)
  })

  it("Makes batchSetFn with linked entity", () => {
    let table = mkTable(
      "test_table",
      ~schemaName="public",
      ~fields=[
        mkField("id", Text, ~fieldSchema=S.string, ~isPrimaryKey),
        mkField("field_a", Numeric, ~fieldSchema=S.bigint),
        mkField("token", Text, ~fieldSchema=S.string, ~linkedEntity="Token"),
      ],
    )

    let batchSetFnString = table->PostgresInterop.makeBatchSetFnString

    let expected = `(sql, rows) => {
      return sql\`
        INSERT INTO "public"."test_table"
        \${sql(rows, "id", "field_a", "token_id")}
        ON CONFLICT(id) DO UPDATE
        SET
        "id" = EXCLUDED."id", "field_a" = EXCLUDED."field_a", "token_id" = EXCLUDED."token_id";\`
    }`

    Assert.equal(batchSetFnString, expected)
  })

  it("Makes batchSetFn with derivedFrom field ", () => {
    let table = mkTable(
      "test_table",
      ~schemaName="public",
      ~fields=[
        mkField("id", Text, ~fieldSchema=S.string, ~isPrimaryKey),
        mkField("field_a", Numeric, ~fieldSchema=S.bigint),
        mkDerivedFromField("tokens", ~derivedFromEntity="Token", ~derivedFromField="token"),
      ],
    )
    let batchSetFnString = table->PostgresInterop.makeBatchSetFnString

    let expected = `(sql, rows) => {
      return sql\`
        INSERT INTO "public"."test_table"
        \${sql(rows, "id", "field_a")}
        ON CONFLICT(id) DO UPDATE
        SET
        "id" = EXCLUDED."id", "field_a" = EXCLUDED."field_a";\`
    }`

    Assert.equal(batchSetFnString, expected)
  })

  it("Does not try to set defaults", () => {
    let table = mkTable(
      "test_table",
      ~schemaName="public",
      ~fields=[
        mkField("id", Text, ~fieldSchema=S.string, ~isPrimaryKey),
        mkField("field_a", Numeric, ~fieldSchema=S.bigint),
        mkField(
          "db_write_timestamp",
          TimestampWithoutTimezone,
          ~fieldSchema=Utils.Schema.dbDate,
          ~default="CURRENT_TIMESTAMP",
        ),
      ],
    )

    let batchSetFnString = table->PostgresInterop.makeBatchSetFnString

    let expected = `(sql, rows) => {
      return sql\`
        INSERT INTO "public"."test_table"
        \${sql(rows, "id", "field_a")}
        ON CONFLICT(id) DO UPDATE
        SET
        "id" = EXCLUDED."id", "field_a" = EXCLUDED."field_a";\`
    }`

    Assert.equal(batchSetFnString, expected)
  })
})
