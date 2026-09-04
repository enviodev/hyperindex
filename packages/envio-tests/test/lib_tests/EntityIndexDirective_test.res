open Vitest

// Asserted against the indexes the tables end up with: a directive that parses
// into the right shape can still resolve to a column the table lacks.

let configYaml = `
name: entity-index-directive
chains:
  - id: 1
    start_block: 0
`

let parse = schema => InternalTestIndexer.fromUserApi(~schema, ~configYaml).config

let table = (schema, name) => {
  let config: Config.t = parse(schema)
  (config.userEntitiesByName->Dict.getUnsafe(name)).table
}

let parseError = schema => InternalTestIndexer.parseError(~schema, ~configYaml)

let schemaWith = index =>
  `
type TestEntity ${index} {
  id: ID!
  tokenId: Int!
  collection: String!
}
`

describe("@index(fields:) column order and direction", () => {
  it("Keeps each index in the order the entity declares it", t => {
    t.expect(
      table(
        `
type TestEntity @index(fields: ["a", "b"]) @index(fields: ["b", "a"]) {
  id: ID!
  a: String!
  b: String!
}
`,
        "TestEntity",
      )->Table.getCompositeIndexes,
      ~message="two indexes over the same columns in opposite order",
    ).toEqual([
      [
        ({fieldName: "a", direction: Table.Asc}: Table.compositeIndexField),
        {fieldName: "b", direction: Table.Asc},
      ],
      [{fieldName: "b", direction: Table.Asc}, {fieldName: "a", direction: Table.Asc}],
    ])
  })

  it("Carries an explicit direction per column", t => {
    t.expect(
      table(
        schemaWith(`@index(fields: [["tokenId", "DESC"], ["collection", "ASC"]])`),
        "TestEntity",
      )->Table.getCompositeIndexes,
      ~message="both columns take the direction they were given",
    ).toEqual([
      [
        ({fieldName: "tokenId", direction: Table.Desc}: Table.compositeIndexField),
        {fieldName: "collection", direction: Table.Asc},
      ],
    ])
  })

  it("Defaults a bare column name to ascending", t => {
    t.expect(
      table(
        schemaWith(`@index(fields: ["tokenId", ["collection", "DESC"]])`),
        "TestEntity",
      )->Table.getCompositeIndexes,
      ~message="the bare name is ascending, the paired one keeps its direction",
    ).toEqual([
      [
        ({fieldName: "tokenId", direction: Table.Asc}: Table.compositeIndexField),
        {fieldName: "collection", direction: Table.Desc},
      ],
    ])
  })

  it("Reads a direction whatever its case", t => {
    t.expect(
      table(
        schemaWith(`@index(fields: [["tokenId", "desc"], ["collection", "asc"]])`),
        "TestEntity",
      )->Table.getCompositeIndexes,
      ~message="lowercase directions parse like uppercase ones",
    ).toEqual([
      [
        ({fieldName: "tokenId", direction: Table.Desc}: Table.compositeIndexField),
        {fieldName: "collection", direction: Table.Asc},
      ],
    ])
  })

  it("Indexes a lone column singly rather than as a composite", t => {
    let table = table(schemaWith(`@index(fields: [["tokenId", "DESC"]])`), "TestEntity")

    t.expect(
      (table->Table.getCompositeIndexes, table->Table.getSingleIndexes),
      ~message="one column is a single index, not a composite one",
    ).toEqual(([], ["tokenId"]))
  })
})

describe("@index(fields:) rejections", () => {
  it("Names the columns available when the entity has no such field", t => {
    t.expect(
      parseError(schemaWith(`@index(fields: ["missing", "tokenId"])`)),
    ).toBe(`schema.graphql:2:17: Invalid \`@index\` on \`TestEntity\`: \`missing\` is not a column of the entity.
  Available columns: \`id\`, \`tokenId\`, \`collection\`.`)
  })

  it("Rejects a @derivedFrom field, which has no column", t => {
    t.expect(
      parseError(`
type User @index(fields: ["tokens", "name"]) {
  id: ID!
  name: String!
  tokens: [Token!]! @derivedFrom(field: "owner")
}

type Token {
  id: ID!
  owner: User!
}
`),
    ).toBe(`schema.graphql:2:11: Invalid \`@index\` on \`User\`: \`tokens\` is a @derivedFrom field, which has no column.
  Use a stored field instead.`)
  })

  it("Indexes id alongside another column", t => {
    t.expect(
      table(
        schemaWith(`@index(fields: ["id", "tokenId"])`),
        "TestEntity",
      )->Table.getCompositeIndexes,
      ~message="only a lone id is redundant — leading a composite is not",
    ).toEqual([
      [
        ({fieldName: "id", direction: Table.Asc}: Table.compositeIndexField),
        {fieldName: "tokenId", direction: Table.Asc},
      ],
    ])
  })

  it("Rejects a lone id, which the primary key already indexes", t => {
    t.expect(
      parseError(schemaWith(`@index(fields: ["id"])`)),
    ).toBe(`schema.graphql:2:17: Invalid \`@index\` on \`TestEntity\`: \`id\` is the primary key, so it is already indexed.
  Remove the \`@index\` directive on it.`)
  })

  it("Rejects a column listed twice in one index", t => {
    t.expect(
      parseError(schemaWith(`@index(fields: ["tokenId", "tokenId"])`)),
    ).toBe(`schema.graphql:2:17: Invalid \`@index\` on \`TestEntity\`: \`tokenId\` is listed twice.
  List each column once — repeating it adds nothing to the index.`)
  })

  it("Rejects the same index declared twice", t => {
    t.expect(
      parseError(
        schemaWith(`@index(fields: ["tokenId", "collection"]) @index(fields: ["tokenId", "collection"])`),
      ),
    ).toBe(`schema.graphql:2:59: Invalid \`@index\` on \`TestEntity\`: the index over \`tokenId\`, \`collection\` is declared twice.
  Remove the duplicate \`@index\` directive.`)
  })

  it("Rejects an index over no columns", t => {
    t.expect(
      parseError(schemaWith(`@index(fields: [])`)),
    ).toBe(`schema.graphql:2:17: Invalid \`@index\` on \`TestEntity\`: no columns are listed.
  List the columns to index, e.g. \`@index(fields: ["tokenId", "owner"])\`.`)
  })

  it("Rejects a column indexed both on the field and on the entity", t => {
    t.expect(
      parseError(`
type TestEntity @index(fields: ["tokenId"]) {
  id: ID!
  tokenId: Int! @index
}
`),
    ).toBe(`schema.graphql:2:17: Invalid \`@index\` on \`TestEntity\`: \`tokenId\` is already marked \`@index\` on the field.
  Keep one of them — the \`@index\` on the field, or \`@index(fields: ["tokenId"])\` on the entity.`)
  })
})
