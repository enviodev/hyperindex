open Vitest

let configYaml = `
name: derived-from
chains:
  - id: 1
    start_block: 0
    contracts:
      - name: Registry
        address: "0x1111111111111111111111111111111111111111"
        events:
          - event: Registered(address indexed owner, uint256 id)
`

let schemaWith = derivedFields => `
type Parent {
  id: ID!
${derivedFields}
}
type Child {
  id: ID!
  parent: Parent!
}
`

let parse = schema => InternalTestIndexer.fromUserApi(~configYaml, ~schema)

let parseError = schema =>
  try {
    parse(schema)->ignore
    "the parse to fail, but it succeeded"
  } catch {
  | JsExn(e) => e->JsExn.message->Option.getOr("an error with a message")
  }

let describeFields = (config: Config.t, entityName) => {
  let {table} = config.userEntities->Array.find(e => e.name === entityName)->Option.getOrThrow
  table.fields->Array.map(field =>
    switch field {
    | Table.Field({fieldName}) => fieldName
    | Table.DerivedFrom({fieldName, derivedFromEntity, derivedFromField}) =>
      `${fieldName} -> ${derivedFromEntity}.${derivedFromField}`
    }
  )
}

let parentFields = spelling =>
  parse(schemaWith(`  children: ${spelling} @derivedFrom(field: "parent")`)).config->describeFields(
    "Parent",
  )

let spellings = ["[Child!]!", "[Child!]", "[Child]!", "[Child]"]

// Every list nullability The Graph accepts describes the same lookup, so each
// one has to reach the runtime as the same derived field — and none of them may
// take a column on the entity that declares it.
let expectedParentFields = ["id", "children -> Child.parent"]

describe("@derivedFrom spellings", () => {
  it("derives from a non-null list of non-null entities", t => {
    t.expect(parentFields("[Child!]!")).toEqual(expectedParentFields)
  })

  it("derives from a nullable list of non-null entities", t => {
    t.expect(parentFields("[Child!]")).toEqual(expectedParentFields)
  })

  it("derives from a non-null list of nullable entities", t => {
    t.expect(parentFields("[Child]!")).toEqual(expectedParentFields)
  })

  it("derives from a nullable list of nullable entities", t => {
    t.expect(parentFields("[Child]")).toEqual(expectedParentFields)
  })

  it("treats all four spellings in one entity as the same lookup", t => {
    let config = parse(
      schemaWith(
        `  strict: [Child!]! @derivedFrom(field: "parent")
  nullableList: [Child!] @derivedFrom(field: "parent")
  nullableItems: [Child]! @derivedFrom(field: "parent")
  nullableBoth: [Child] @derivedFrom(field: "parent")`,
      ),
    ).config

    t.expect(config->describeFields("Parent")).toEqual([
      "id",
      "strict -> Child.parent",
      "nullableList -> Child.parent",
      "nullableItems -> Child.parent",
      "nullableBoth -> Child.parent",
    ])
  })

  // A derived field is read by looking the owner's id up on the other table, so
  // the relation is only usable if that column is indexed. The four spellings
  // point at one column, and the index is emitted once.
  it("indexes the column a derived lookup reads, once per column", t => {
    let indexes = spelling =>
      PgStorage.getSchemaIndexes(
        ~entities=parse(
          schemaWith(
            `  children: ${spelling} @derivedFrom(field: "parent")
  alias: ${spelling} @derivedFrom(field: "parent")`,
          ),
        ).config.userEntities,
      )->Array.map(IndexDefinition.describe)

    t.expect(spellings->Array.map(indexes)).toEqual(
      spellings->Array.map(_ => ["Child(parent_id) using btree"]),
    )
  })

  it("rejects a derived field that is not an entity", t => {
    t.expect(
      parseError(schemaWith(`  children: [String!]! @derivedFrom(field: "parent")`)),
    ).toEqual(
      `schema.graphql:4:3: Failed parsing field children on entity Parent: Field marked with @derivedFrom directive does not meet the required structure. Field should be a list of entities, for example: [<ENTITY_NAME>!]! @derivedFrom(field: "parent")`,
    )
  })

  // Loosening the shape must not start accepting a list of lists: there is no
  // nesting on the other side of the relation for it to describe.
  it("rejects a derived field nested in a list of lists", t => {
    t.expect(
      parseError(schemaWith(`  children: [[Child!]!]! @derivedFrom(field: "parent")`)),
    ).toEqual(
      `schema.graphql:4:3: Failed parsing field children on entity Parent: Field marked with @derivedFrom directive does not meet the required structure. Field should be a list of entities, for example: [<ENTITY_NAME>!]! @derivedFrom(field: "parent")`,
    )
  })

  // A derived field surfaces as a list everywhere it is read — through the child
  // entity in a handler, as an array relationship in the GraphQL API — so the
  // one-to-one spelling is refused rather than quietly answered with an array.
  it("rejects a one-to-one derived field", t => {
    t.expect(parseError(schemaWith(`  child: Child @derivedFrom(field: "parent")`))).toEqual(
      `schema.graphql:4:3: Failed parsing field child on entity Parent: Field marked with @derivedFrom directive does not meet the required structure. Field should be a list of entities, for example: [<ENTITY_NAME>!]! @derivedFrom(field: "parent")`,
    )
  })

  it("rejects a derived field naming an enum", t => {
    t.expect(
      parseError(`
enum Status { ACTIVE }
type Parent {
  id: ID!
  statuses: [Status!]! @derivedFrom(field: "parent")
}
`),
    ).toEqual(
      "Cannot derive field parent from enum Status. derivedFrom is intended to be used with Entity type definitions",
    )
  })
})

// The generated entity type has no key for a derived field: it is computed from
// the other table, so a handler has nothing to write to it.
let _ = InternalTestIndexer.fromUserApi(
  ~configYaml,
  ~schema=schemaWith(`  children: [Child!] @derivedFrom(field: "parent")`),
  ~handlers=`
import { indexer } from "envio";

indexer.onEvent({ contract: "Registry", event: "Registered" }, async ({ event, context }) => {
  context.Parent.set({ id: event.params.owner });
  context.Child.set({ id: event.params.id.toString(), parent_id: event.params.owner });
});
`,
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer, type Parent, TestHelpers } from "envio";

const { Addresses } = TestHelpers;

describe("@derivedFrom on a nullable list", () => {
  it("stores no column for the derived field and links the child back", async (t) => {
    const indexer = createTestIndexer();
    const owner = Addresses.defaultAddress;

    await indexer.process({
      chains: {
        1: {
          simulate: [
            { contract: "Registry", event: "Registered", params: { owner, id: 7n } },
          ],
        },
      },
    });

    const parent: Parent = { id: owner };
    t.expect([
      await indexer.Parent.getOrThrow(owner),
      await indexer.Child.getWhere({ parent_id: { _eq: owner } }),
    ]).toEqual([parent, [{ id: "7", parent_id: owner }]]);
  });
});
`,
)
