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
  List each column once: repeating it adds nothing to the index.`)
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
  Keep one of them: the \`@index\` on the field, or \`@index(fields: ["tokenId"])\` on the entity.`)
  })
})

describe("@index(include:)", () => {
  it("Reaches the config the storage builds its indexes from", t => {
    let config = parse(
      schemaWith(`@index(fields: ["tokenId", "collection"]) @index(fields: [["tokenId", "DESC"]], include: ["id", "collection"])`),
    )
    let entities = (
      config.envioInfo->(Utils.magic: JSON.t => {"entities": array<{..}>})
    )["entities"]
    t.expect(
      entities->Array.map(entity => (entity["compositeIndices"], entity["coveringIndices"])),
    ).toEqual([
      (
        [
          [
            {"fieldName": "tokenId", "direction": "Asc"},
            {"fieldName": "collection", "direction": "Asc"},
          ],
        ],
        [
          {
            "fields": [{"fieldName": "tokenId", "direction": "Desc"}],
            "include": ["collection", "id"],
          },
        ],
      ),
    ])
  })
})

describe("@index(include:) rejections", () => {
  it("Names the columns available when an included field doesn't exist", t => {
    t.expect(
      parseError(schemaWith(`@index(fields: ["tokenId"], include: ["missing"])`)),
    ).toBe(`schema.graphql:2:17: Invalid \`@index\` on \`TestEntity\`: \`missing\` is not a column of the entity.
  Available columns: \`id\`, \`tokenId\`, \`collection\`.`)
  })

  it("Rejects a column that is both keyed on and included", t => {
    t.expect(
      parseError(schemaWith(`@index(fields: ["tokenId", "collection"], include: ["collection"])`)),
    ).toBe(`schema.graphql:2:17: Invalid \`@index\` on \`TestEntity\`: \`collection\` is both a key column in \`fields\` and listed in \`include\`.
  Drop it from \`include\`: the index already stores every column it is keyed on.`)
  })

  it("Rejects a column included twice", t => {
    t.expect(
      parseError(schemaWith(`@index(fields: ["tokenId"], include: ["collection", "collection"])`)),
    ).toBe(`schema.graphql:2:17: Invalid \`@index\` on \`TestEntity\`: \`collection\` is listed twice.
  List each column once: repeating it adds nothing to the index.`)
  })

  it("Rejects an include that lists nothing", t => {
    t.expect(
      parseError(schemaWith(`@index(fields: ["tokenId"], include: [])`)),
    ).toBe(`schema.graphql:2:17: Invalid \`@index\` on \`TestEntity\`: \`include\` lists no columns.
  List the columns the index should carry, e.g. \`include: ["balance"]\`, or drop \`include\`.`)
  })

  it("Rejects an included column given a direction", t => {
    t.expect(
      parseError(schemaWith(`@index(fields: ["tokenId"], include: [["collection", "DESC"]])`)),
    ).toBe(`schema.graphql:2:17: Invalid \`@index\` on \`TestEntity\`: \`include\` should list field names as strings, e.g. \`include: ["balance"]\`. An included column has no direction.`)
  })

  it("Rejects the same covering index declared twice, whatever order it includes in", t => {
    t.expect(
      parseError(
        schemaWith(`@index(fields: ["tokenId"], include: ["id", "collection"]) @index(fields: ["tokenId"], include: ["collection", "id"])`),
      ),
    ).toBe(`schema.graphql:2:76: Invalid \`@index\` on \`TestEntity\`: the index over \`tokenId\` including \`collection\`, \`id\` is declared twice.
  Remove the duplicate \`@index\` directive.`)
  })

  it("Rejects a covering index over a column already indexed on the field", t => {
    t.expect(
      parseError(`
type TestEntity @index(fields: ["tokenId"], include: ["collection"]) {
  id: ID!
  tokenId: Int! @index
  collection: String!
}
`),
    ).toBe(`schema.graphql:2:17: Invalid \`@index\` on \`TestEntity\`: \`tokenId\` is already marked \`@index\` on the field, and this index serves every query that one does.
  Remove the \`@index\` on the field.`)
  })

  it("Rejects an argument an index doesn't take", t => {
    t.expect(
      parseError(schemaWith(`@index(fields: ["tokenId"], includes: ["collection"])`)),
    ).toBe(`schema.graphql:2:17: Invalid \`@index\` on \`TestEntity\`: Unknown argument \`includes\`. An \`@index\` takes \`fields\` and, optionally, \`include\`.`)
  })
})
