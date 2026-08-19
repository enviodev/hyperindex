open Vitest

// The rest of this suite moved to packages/envio-tests; these proofs stay
// because they type-check against the generated Indexer module.
describe("Generated entity id scalars", () => {
  it("type-checks the generated accessors below", t => t.expect(true).toBe(true))
})

// Compile-time proof that the generated user-facing API keys each entity's
// operations by its real id scalar. These functions are type-checked, never
// run: `IntIdEntity` id is `int`, `BigIntIdEntity` id is `bigint`, and its
// foreign key `numericRef_id` adopts the referenced `Int` id. Passing a string
// where a numeric id is expected would fail to compile.
let _handlerContextKeysOpsByIdScalar = async (context: Indexer.handlerContext) => {
  context.\"IntIdEntity".set({id: 1, value: "x"})
  let _: option<Indexer.Entities.IntIdEntity.t> = await context.\"IntIdEntity".get(1)
  let _ = await context.\"IntIdEntity".getOrThrow(1)
  context.\"IntIdEntity".deleteUnsafe(1)

  context.\"BigIntIdEntity".set({id: 1n, numericRef_id: 2})
  let _ = await context.\"BigIntIdEntity".get(1n)
  context.\"BigIntIdEntity".deleteUnsafe(1n)
}

let _testIndexerKeysOpsByIdScalar = async (indexer: Indexer.testIndexer) => {
  let _: option<Indexer.Entities.IntIdEntity.t> = await indexer.\"IntIdEntity".get(1)
  let _ = await indexer.\"IntIdEntity".getOrThrow(1)
  indexer.\"IntIdEntity".set({id: 1, value: "x"})
  let _ = await indexer.\"BigIntIdEntity".get(1n)
}

// The name-keyed accessor resolves the id through the `name` GADT, so the helper
// form is keyed by the same scalar as direct field access above — passing a
// string id to a numeric entity here would fail to compile.
let _testIndexerHelperKeysOpsByIdScalar = async (indexer: Indexer.testIndexer) => {
  let intOps = indexer->Indexer.getTestIndexerEntityOperations(IntIdEntity)
  let _: option<Indexer.Entities.IntIdEntity.t> = await intOps.get(1)
  let _ = await intOps.getOrThrow(1)

  let bigIntOps = indexer->Indexer.getTestIndexerEntityOperations(BigIntIdEntity)
  let _: option<Indexer.Entities.BigIntIdEntity.t> = await bigIntOps.get(1n)

  // A plain `ID!` entity still takes a string, unchanged.
  let userOps = indexer->Indexer.getTestIndexerEntityOperations(User)
  let _: option<Indexer.Entities.User.t> = await userOps.get("u1")
}

