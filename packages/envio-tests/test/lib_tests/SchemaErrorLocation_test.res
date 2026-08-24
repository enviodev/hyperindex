open Vitest

// Schema errors carry `<file>:<line>:<column>` so an editor can jump to the
// offending directive rather than the reader hunting for it.

let parseError = schema =>
  try {
    InternalTestIndexer.fromUserApi(
      ~schema,
      ~configYaml=`
name: schema-error-location
chains:
  - id: 1
    start_block: 0
`,
    )->ignore
    "the parse to fail, but it succeeded"
  } catch {
  | JsExn(e) => e->JsExn.message->Option.getOr("an error with a message")
  }

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
