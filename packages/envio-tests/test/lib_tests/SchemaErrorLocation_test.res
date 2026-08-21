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
  // Counted by hand against the schema below: `Second` starts line 7, and its
  // `@index` sits at column 15 — `type Second @index(...)`, with `@` the 13th
  // character. Both are 1-based.
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
  Available columns: \`value\`.`)
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
})
