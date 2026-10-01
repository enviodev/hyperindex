open Vitest

let configYaml = (~schemaPath=?) =>
  `
name: schema-error-location
${switch schemaPath {
    | Some(path) => `schema: ${path}`
    | None => ""
    }}
chains:
  - id: 1
    start_block: 0
`

let parseError = (~schemaPath=?, schema) =>
  InternalTestIndexer.parseError(~schema, ~configYaml=configYaml(~schemaPath?))

let storageDirectiveHint = `Expected args from {postgres, clickhouse}: \`postgres\` takes a boolean, \`clickhouse\` takes a boolean or a table options object, e.g. @storage(postgres: true, clickhouse: true) or @storage(clickhouse: {partitionBy: "toYYYYMM(timestamp)", orderBy: ["timestamp"], ttl: "timestamp + INTERVAL 2 YEAR"}).`

describe("Schema error locations", () => {
  it("Points at the line and column of the offending directive", t => {
    t.expect(
      parseError(`type First {
  id: ID!
  value: String!
}

# a comment, so the line count can't be a coincidence
type Second @index(fields: ["missing"]) {
  id: ID!
  value: String!
}
`),
    ).toBe(`schema.graphql:7:13: Invalid \`@index\` on \`Second\`: \`missing\` is not a column of the entity.
  Available columns: \`id\`, \`value\`.`)
  })

  it("Points at the entity for an error about the entity itself", t => {
    t.expect(
      parseError(`type First {
  id: ID!
}

type Second {
  value: String!
}
`),
    ).toBe(
      "schema.graphql:5:1: No 'id' field found on entity Second. Please add an 'id' field to your entity.",
    )
  })

  it("Points at the field for an error about one field", t => {
    t.expect(
      parseError(`type First {
  id: ID! @index
  value: String!
}
`),
    ).toBe(
      "schema.graphql:2:3: Failed parsing field id on entity First: The field 'id' or 'ID' cannot be indexed or derivedFrom. Please remove the @index or @derivedFrom directive from field id",
    )
  })

  it("Counts the leading blank lines the caller wrote", t => {
    t.expect(
      parseError(`

type First @index(fields: ["missing"]) {
  id: ID!
  value: String!
}
`),
    ).toBe(`schema.graphql:3:12: Invalid \`@index\` on \`First\`: \`missing\` is not a column of the entity.
  Available columns: \`id\`, \`value\`.`)
  })

  it("Counts a comment line once when the schema uses CRLF", t => {
    t.expect(
      parseError(
        `# a comment
type First @index(fields: ["missing"]) {
  id: ID!
  value: String!
}
`->String.replaceAll("\n", "\r\n"),
      ),
    ).toBe(`schema.graphql:2:12: Invalid \`@index\` on \`First\`: \`missing\` is not a column of the entity.
  Available columns: \`id\`, \`value\`.`)
  })

  it("Names the schema the way config.yaml configured it", t => {
    t.expect(
      parseError(
        ~schemaPath="./db/custom.graphql",
        `type First @index(fields: ["missing"]) {
  id: ID!
  value: String!
}
`,
      ),
    ).toBe(`db/custom.graphql:1:12: Invalid \`@index\` on \`First\`: \`missing\` is not a column of the entity.
  Available columns: \`id\`, \`value\`.`)
  })

  it("Points at the repeated directive for a flag declared twice", t => {
    t.expect(
      parseError(`type First @crossChain @crossChain {
  id: ID!
}
`),
    ).toBe(
      "schema.graphql:1:24: Invalid @crossChain directive on `First`. Only one @crossChain directive is allowed per entity.",
    )
  })

  it("Points at the repeated directive for a storage directive declared twice", t => {
    t.expect(
      parseError(`type First @storage(postgres: true) @storage(clickhouse: true) {
  id: ID!
}
`),
    ).toBe(
      `schema.graphql:1:37: Invalid @storage directive on \`First\`. Only one @storage directive is allowed per entity. ${storageDirectiveHint}`,
    )
  })

  it("Points at the duplicate index rather than the entity holding it", t => {
    t.expect(
      parseError(`type First
  @index(fields: ["a", "b"])
  @index(fields: ["a", "b"]) {
  id: ID!
  a: String!
  b: String!
}
`),
    ).toBe(`schema.graphql:3:3: Invalid \`@index\` on \`First\`: the index over \`a\`, \`b\` is declared twice.
  Remove the duplicate \`@index\` directive.`)
  })
})
