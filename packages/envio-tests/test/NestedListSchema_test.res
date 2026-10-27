open Vitest

let configYaml = `
name: nested-list-schema
chains:
  - id: 1
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 0
    contracts:
      - name: Token
        address: "0x0000000000000000000000000000000000000001"
        events:
          - event: Transfer(address indexed from, address indexed to, uint256 value)
`

describe("A list of lists in the schema", () => {
  it("is refused, whatever the nullability of the inner list", t => {
    let messageFor = fieldType =>
      (
        () =>
          Core.fromUserApi(
            ~schema=`
type Grid {
  id: ID!
  cells: ${fieldType}
}
`,
            configYaml,
          )
      )->messageOfThrown

    t.expect([
      messageFor("[[Int!]!]!"),
      messageFor("[[Int!]]!"),
      messageFor("[[[String!]!]!]"),
    ]).toEqual([
      Some(
        "The field \"cells\" on \"Grid\" has the type [[Int!]!]!, a list of lists, which is not supported. Store it as Json, or as a list of a type of its own.",
      ),
      Some(
        "The field \"cells\" on \"Grid\" has the type [[Int!]]!, a list of lists, which is not supported. Store it as Json, or as a list of a type of its own.",
      ),
      Some(
        "The field \"cells\" on \"Grid\" has the type [[[String!]!]!], a list of lists, which is not supported. Store it as Json, or as a list of a type of its own.",
      ),
    ])
  })
})
