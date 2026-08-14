open Vitest

let makeRow = IndexFixtures.makeRow
let entry = IndexFixtures.makeEntry

describe("Index identity", () => {
  Async.it("Keys an index by table, method and ordered columns with direction", async t => {
    t.expect((
      IndexDefinition.single(~tableName="Token", ~column="owner_id")->IndexDefinition.key,
      IndexDefinition.make(
        ~tableName="Transfer",
        ~columns=[
          {name: "block_number", direction: Table.Desc},
          {name: "log_index", direction: Table.Asc},
        ],
      )->IndexDefinition.key,
    )).toEqual(("Token|btree|owner_id", "Transfer|btree|block_number DESC,log_index"))
  })

  Async.it("Distinguishes column order, direction and access method", async t => {
    let key = (~columns, ~method) =>
      IndexDefinition.make(~tableName="Transfer", ~columns, ~method)->IndexDefinition.key
    let a: IndexDefinition.column = {name: "a", direction: Table.Asc}
    let b: IndexDefinition.column = {name: "b", direction: Table.Asc}

    t.expect(
      [
        key(~columns=[a, b], ~method="btree"),
        key(~columns=[b, a], ~method="btree"),
        key(~columns=[a, b], ~method="hash"),
        key(~columns=[{...a, direction: Table.Desc}, b], ~method="btree"),
      ]->Set.fromArray->Set.size,
      ~message="Each variation must be a distinct index identity",
    ).toBe(4)
  })
})

describe("Generated index names", () => {
  Async.it("Is stable for one identity, so a restart finds what it built", async t => {
    let name = () =>
      IndexDefinition.single(~tableName="Token", ~column="owner_id")->IndexDefinition.name

    t.expect((name(), name() === name())).toEqual(("Token_owner_id_548uhmhvrh", true))
  })

  // `<table>_<column>` alone can't tell these apart — the underscore is part of
  // one name in each. The hash is taken over the structured identity, so it can.
  Async.it("Separates identities that flatten to the same readable prefix", async t => {
    let ab_c = IndexDefinition.single(~tableName="A_B", ~column="C")
    let a_bc = IndexDefinition.single(~tableName="A", ~column="B_C")

    t.expect(
      (
        ab_c->IndexDefinition.readablePrefix === a_bc->IndexDefinition.readablePrefix,
        ab_c->IndexDefinition.name === a_bc->IndexDefinition.name,
      ),
      ~message="Same readable prefix, different index — the names must not collide",
    ).toEqual((true, false))
  })

  // Postgres truncates identifiers at 63 bytes on its own, so two long field
  // names used to collapse onto one name and the second index silently never
  // got built.
  Async.it("Separates identities whose first 63 characters are identical", async t => {
    let tableName = "Entity" ++ "x"->String.repeat(50)
    let one = IndexDefinition.single(~tableName, ~column="some_long_column_one")
    let two = IndexDefinition.single(~tableName, ~column="some_long_column_two")

    t.expect((
      one->IndexDefinition.readablePrefix->String.slice(~start=0, ~end=63) ===
        two->IndexDefinition.readablePrefix->String.slice(~start=0, ~end=63),
      one->IndexDefinition.name === two->IndexDefinition.name,
    )).toEqual((true, false))
  })

  Async.it("Never exceeds Postgres' 63-byte identifier limit", async t => {
    let long = "x"->String.repeat(200)
    let names = [
      IndexDefinition.single(~tableName="Token", ~column="owner_id"),
      IndexDefinition.single(~tableName=long, ~column=long),
      IndexDefinition.make(
        ~tableName=long,
        ~columns=[
          {name: long, direction: Table.Desc},
          {name: long, direction: Table.Asc},
        ],
      ),
    ]->Array.map(IndexDefinition.name)

    t.expect(
      (
        names->Array.map(String.length),
        names->Array.every(name => name->String.endsWith(name->String.slice(~start=53, ~end=63))),
      ),
      ~message="The readable half is truncated; the identity hash is always kept whole",
    ).toEqual(([25, 63, 63], true))
  })

  Async.it("Emits DDL that carries the generated name and the column directions", async t => {
    let definition = IndexDefinition.make(
      ~tableName="Transfer",
      ~columns=[
        {name: "block_number", direction: Table.Desc},
        {name: "log_index", direction: Table.Asc},
      ],
    )
    let name = definition->IndexDefinition.name

    t.expect(
      definition->IndexDefinition.makeCreateQuery(~pgSchema="s"),
      ~message="No IF NOT EXISTS: a skipped create must not look like a successful one",
    ).toBe(`CREATE INDEX "${name}" ON "s"."Transfer"("block_number" DESC, "log_index");`)
  })
})

describe("Matching the catalog against a desired index", () => {
  let ownerIdIndex = IndexDefinition.single(~tableName="Token", ~column="owner_id")

  // An index built by an older version carries a name we'd never generate now.
  // Matching on identity rather than name keeps it, instead of building a
  // duplicate beside it.
  Async.it("Accepts a valid legacy index that covers the wanted identity", async t => {
    let legacy = makeRow(~tableName="Token", ~indexName="Token_owner_id", ~columns=["owner_id"])

    t.expect((
      legacy->entry->IndexCatalog.satisfies(ownerIdIndex, ~coverage=LeadingColumns),
      legacy->entry->IndexCatalog.rejectReason(ownerIdIndex, ~coverage=LeadingColumns),
    )).toEqual((true, None))
  })

  Async.it("Rejects an index PostgreSQL reports as invalid", async t => {
    let broken = makeRow(
      ~tableName="Token",
      ~indexName="Token_owner_id",
      ~columns=["owner_id"],
      ~isValid=0,
    )

    t.expect((
      broken->entry->IndexCatalog.satisfies(ownerIdIndex, ~coverage=LeadingColumns),
      broken->entry->IndexCatalog.rejectReason(ownerIdIndex, ~coverage=LeadingColumns),
    )).toEqual((false, Some("PostgreSQL reports it as invalid or not ready")))
  })

  // A WHERE clause only covers rows inside the predicate, so it can't answer
  // the unrestricted lookups a getWhere filter makes.
  Async.it("Rejects a partial index for a full-index request", async t => {
    let partial = makeRow(
      ~tableName="Token",
      ~indexName="Token_owner_id",
      ~columns=["owner_id"],
      ~isPartial=1,
      ~predicate=`("owner_id" IS NOT NULL)`,
    )

    t.expect((
      partial->entry->IndexCatalog.satisfies(ownerIdIndex, ~coverage=LeadingColumns),
      partial->entry->IndexCatalog.rejectReason(ownerIdIndex, ~coverage=LeadingColumns),
    )).toEqual((
      false,
      Some(`it is partial (WHERE ("owner_id" IS NOT NULL)), so it only covers part of the table`),
    ))
  })

  Async.it("Rejects an expression index and a mismatched access method", async t => {
    let expression = makeRow(
      ~tableName="Token",
      ~indexName="Token_lower_owner",
      ~columns=[`lower("owner_id")`],
      ~isExpression=1,
    )
    let hash = makeRow(
      ~tableName="Token",
      ~indexName="Token_owner_hash",
      ~columns=["owner_id"],
      ~method="hash",
    )

    t.expect((
      expression->entry->IndexCatalog.rejectReason(ownerIdIndex, ~coverage=LeadingColumns),
      hash->entry->IndexCatalog.rejectReason(ownerIdIndex, ~coverage=LeadingColumns),
    )).toEqual((
      Some("it indexes an expression rather than plain columns"),
      Some("it uses the hash access method, not btree"),
    ))
  })

  // A btree on (a, b) is sorted by `a` first, so it serves everything a btree on
  // (a) does. Nothing in it is ordered by `b` alone.
  Async.it("Lets a composite index stand in for its leading column only", async t => {
    let composite = makeRow(~tableName="Token", ~indexName="Token_a_b", ~columns=["a", "b"])

    t.expect((
      composite->entry->IndexCatalog.satisfies(IndexDefinition.single(~tableName="Token", ~column="a"), ~coverage=LeadingColumns),
      composite->entry->IndexCatalog.satisfies(IndexDefinition.single(~tableName="Token", ~column="b"), ~coverage=LeadingColumns),
    )).toEqual((true, false))
  })

  Async.it("Finds the covering index across the whole schema, or nothing", async t => {
    let catalog = IndexCatalog.fromRows(
      ~rows=[
        makeRow(~tableName="Token", ~indexName="Token_a_b", ~columns=["a", "b"]),
        makeRow(~tableName="Transfer", ~indexName="Transfer_a", ~columns=["a"]),
      ],
    )

    t.expect(
      (
        catalog
        ->IndexCatalog.find(IndexDefinition.single(~tableName="Token", ~column="a"), ~coverage=LeadingColumns)
        ->Option.map((e: IndexCatalog.entry) => e.name),
        catalog
        ->IndexCatalog.find(IndexDefinition.single(~tableName="Token", ~column="b"), ~coverage=LeadingColumns)
        ->Option.map((e: IndexCatalog.entry) => e.name),
      ),
      ~message="Table names are part of the identity, so Transfer_a can't serve Token",
    ).toEqual((Some("Token_a_b"), None))
  })
})
