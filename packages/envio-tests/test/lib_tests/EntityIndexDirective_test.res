open Vitest

// The indexes a directive resolves to are asserted where they are derived, in
// `packages/cli/src/postgres/schema_indexes.rs`; these are the directives the
// config refuses.

let configYaml = `
name: entity-index-directive
chains:
  - id: 1
    start_block: 0
`

let parse = schema => InternalTestIndexer.fromUserApi(~schema, ~configYaml).config

let parseError = schema => InternalTestIndexer.parseError(~schema, ~configYaml)

let schemaWith = index =>
  `
type TestEntity ${index} {
  id: ID!
  tokenId: Int!
  collection: String!
}
`

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
