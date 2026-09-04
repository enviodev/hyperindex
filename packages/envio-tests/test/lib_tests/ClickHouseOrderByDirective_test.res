open Vitest

// A ClickHouse sorting key can't hold a nullable, array or String-stored
// column, so those are rejected against the schema rather than left to fail at
// CREATE TABLE.

let configYaml = `
name: clickhouse-order-by-directive
storage:
  postgres:
    default: true
  clickhouse:
    default: true
chains:
  - id: 1
    start_block: 0
`

let parse = schema => InternalTestIndexer.fromUserApi(~schema, ~configYaml).config

let parseError = schema => InternalTestIndexer.parseError(~schema, ~configYaml)

describe("clickhouse.orderBy column references", () => {
  it("Names the columns available when the entity has no such field", t => {
    t.expect(
      parseError(`
type Token @storage(clickhouse: {orderBy: ["missing"]}) {
  id: ID!
  timestamp: Timestamp!
}
`),
    ).toBe(`schema.graphql:2:12: Invalid \`clickhouse.orderBy\` on \`Token\`: \`missing\` is not a column of the entity.
  Available columns: \`id\`, \`timestamp\`.`)
  })

  it("Rejects a lone id, which is the sorting key when no orderBy is given", t => {
    t.expect(
      parseError(`
type Token @storage(clickhouse: {orderBy: ["id"]}) {
  id: ID!
}
`),
    ).toBe(`schema.graphql:2:12: Invalid \`clickhouse.orderBy\` on \`Token\`: \`id\` on its own is already the sorting key when no \`orderBy\` is given.
  Drop the \`orderBy\`, or add the columns to sort by alongside \`id\`.`)
  })

  it("Sorts by id alongside another column", t => {
    let config = parse(`
type Token @storage(clickhouse: {orderBy: ["id", "timestamp"]}) {
  id: ID!
  timestamp: Timestamp!
}
`)

    t.expect(
      ClickHouse.entitySpec(
        ~entityConfig=config.userEntitiesByName->Dict.getUnsafe("Token"),
      ).orderBy,
      ~message="id leads a sorting key that narrows further",
    ).toEqual(Some(["id", "timestamp"]))
  })

  it("Rejects an empty list, which would sort by nothing at all", t => {
    t.expect(
      parseError(`
type Token @storage(clickhouse: {orderBy: []}) {
  id: ID!
  timestamp: Timestamp!
}
`),
      ~message="an orderBy that resolves to no columns is a silent no-op otherwise",
    ).toBe(`schema.graphql:2:12: Invalid @storage directive on \`Token\`. \`clickhouse.orderBy\` must be a non-empty list of entity field names, e.g. clickhouse: {orderBy: ["timestamp"]}.`)
  })

  it("Rejects a column listed twice", t => {
    t.expect(
      parseError(`
type Token @storage(clickhouse: {orderBy: ["timestamp", "timestamp"]}) {
  id: ID!
  timestamp: Timestamp!
}
`),
    ).toBe(`schema.graphql:2:12: Invalid \`clickhouse.orderBy\` on \`Token\`: \`timestamp\` is listed twice.
  List each column once — repeating it adds nothing to the sorting key.`)
  })

  it("Rejects a nullable column, which ClickHouse won't sort by", t => {
    t.expect(
      parseError(`
type Token @storage(clickhouse: {orderBy: ["timestamp"]}) {
  id: ID!
  timestamp: Timestamp
}
`),
    ).toBe(`schema.graphql:2:12: Invalid \`clickhouse.orderBy\` on \`Token\`: \`timestamp\` is nullable, and ClickHouse won't sort by a nullable column.
  Make the field non-nullable to sort by it.`)
  })

  it("Rejects an array column, which ClickHouse won't sort by", t => {
    t.expect(
      parseError(`
type Token @storage(clickhouse: {orderBy: ["tags"]}) {
  id: ID!
  tags: [String!]!
}
`),
    ).toBe(`schema.graphql:2:12: Invalid \`clickhouse.orderBy\` on \`Token\`: \`tags\` is an array, and ClickHouse won't sort by an array column.
  Sort by a scalar field instead.`)
  })

  it("Rejects a @derivedFrom field, which has no column", t => {
    t.expect(
      parseError(`
type Token @storage(clickhouse: {orderBy: ["transfers"]}) {
  id: ID!
  transfers: [Transfer!]! @derivedFrom(field: "token")
}

type Transfer @storage(clickhouse: true) {
  id: ID!
  token: Token!
}
`),
    ).toBe(`schema.graphql:2:12: Invalid \`clickhouse.orderBy\` on \`Token\`: \`transfers\` is a @derivedFrom field, which has no column.
  Use a stored field instead.`)
  })
})

describe("clickhouse.orderBy on columns ClickHouse stores as String", () => {
  // A BigInt/BigDecimal only keeps numeric ordering when it fits a Decimal —
  // see getClickHouseFieldType in ClickHouse.res.
  let schema = (type_, config) =>
    `
type Token @storage(clickhouse: {orderBy: ["amount"]}) {
  id: ID!
  amount: ${type_}!${config}
}
`

  it("Rejects a BigInt with no precision", t => {
    t.expect(parseError(schema("BigInt", ""))).toBe(
      "Invalid storage for `Token`. `clickhouse.orderBy` sorts by `amount`, which stores a BigInt that ClickHouse keeps as a String (sorted lexicographically, not numerically) unless a precision is set. Add `@config(precision: N)` with N <= 38 to the BigInt it stores so it sorts as a numeric Decimal.",
    )
  })

  it("Rejects a BigInt whose precision overflows a Decimal", t => {
    t.expect(parseError(schema("BigInt", " @config(precision: 39)"))).toBe(
      "Invalid storage for `Token`. `clickhouse.orderBy` sorts by `amount`, which stores a BigInt that ClickHouse keeps as a String (sorted lexicographically, not numerically) unless a precision is set. Add `@config(precision: N)` with N <= 38 to the BigInt it stores so it sorts as a numeric Decimal.",
    )
  })

  it("Rejects a BigDecimal with no precision", t => {
    t.expect(parseError(schema("BigDecimal", ""))).toBe(
      "Invalid storage for `Token`. `clickhouse.orderBy` sorts by `amount`, which stores a BigDecimal that ClickHouse keeps as a String (sorted lexicographically, not numerically) unless a precision is set. Add `@config(precision: N, scale: M)` with M <= N <= 38 to the BigDecimal it stores so it sorts as a numeric Decimal.",
    )
  })

  it("Rejects a BigDecimal whose scale overflows its precision", t => {
    t.expect(parseError(schema("BigDecimal", " @config(precision: 10, scale: 20)"))).toBe(
      "Invalid storage for `Token`. `clickhouse.orderBy` sorts by `amount`, which stores a BigDecimal that ClickHouse keeps as a String (sorted lexicographically, not numerically) unless a precision is set. Add `@config(precision: N, scale: M)` with M <= N <= 38 to the BigDecimal it stores so it sorts as a numeric Decimal.",
    )
  })

  it("Sorts by a BigInt that fits a Decimal", t => {
    let config = parse(schema("BigInt", " @config(precision: 38)"))

    let spec = ClickHouse.entitySpec(
      ~entityConfig=config.userEntitiesByName->Dict.getUnsafe("Token"),
    )

    t.expect(
      (spec.columns->Array.map(column => (column.fieldType, column.precision)), spec.orderBy),
      ~message="a bounded BigInt stores as a Decimal, which sorts numerically",
    ).toEqual(([("String", None), ("BigInt", Some(38))], Some(["amount"])))
  })
})
