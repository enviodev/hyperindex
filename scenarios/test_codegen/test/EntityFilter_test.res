open Vitest

external toUnknown: 'a => unknown = "%identity"
external asEntity: dict<unknown> => Internal.entity = "%identity"

describe("EntityFilter.toOperationKey", () => {
  it("Replaces filter values with $N placeholders", t => {
    let v = 0->(Utils.magic: int => unknown)
    t.expect(
      [
        EntityFilter.Eq({fieldName: "a", fieldValue: v}),
        EntityFilter.Gt({fieldName: "a", fieldValue: v}),
        EntityFilter.Lt({fieldName: "a", fieldValue: v}),
        EntityFilter.In({fieldName: "a", fieldValue: [v]}),
        EntityFilter.And({
          filters: [
            EntityFilter.Gt({fieldName: "a", fieldValue: v}),
            EntityFilter.Lt({fieldName: "b", fieldValue: v}),
          ],
        }),
      ]->Array.map(filter => filter->EntityFilter.toOperationKey(~entityName="User")),
    ).toEqual([
      "User.getWhere({a: $1})",
      "User.getWhere({a: {_gt: $1}})",
      "User.getWhere({a: {_lt: $1}})",
      "User.getWhere({a: {_in: $1}})",
      "User.getWhere({a: {_gt: $1}, b: {_lt: $2}})",
    ])
  })
})

describe("EntityFilter.parseGetWhereOrThrow", () => {
  let table = Table.mkTable(
    "users",
    ~fields=[
      Table.mkField("id", String, ~isPrimaryKey=true, ~fieldSchema=S.string),
      Table.mkField("score", Int32, ~isIndex=true, ~fieldSchema=S.int),
      Table.mkField("name", String, ~fieldSchema=S.string),
      Table.mkField("owner", Entity({name: "Owner"}), ~linkedEntity="Owner", ~fieldSchema=S.string),
      Table.mkDerivedFromField("tokens", ~derivedFromEntity="Token", ~derivedFromField="owner"),
    ],
  )

  // The filter comes from user-land JS, so test inputs are raw objects
  let parse = (filter: 'a) =>
    filter
    ->(Utils.magic: 'a => dict<dict<unknown>>)
    ->EntityFilter.parseGetWhereOrThrow(~entityName="User", ~table)

  let v = (value: int) => value->(Utils.magic: int => unknown)

  it("Parses every operator into the filters to load", t => {
    t.expect([
      parse(%raw(`{score: {_eq: 1}}`)),
      parse(%raw(`{score: {_gt: 1}}`)),
      parse(%raw(`{score: {_lt: 1}}`)),
      parse(%raw(`{score: {_gte: 1}}`)),
      parse(%raw(`{score: {_lte: 1}}`)),
      parse(%raw(`{score: {_in: [1, 2]}}`)),
      parse(%raw(`{score: {_in: []}}`)),
      // Unindexed linked entity fields are allowed via the _id api name
      parse(%raw(`{owner_id: {_eq: 1}}`)),
      // Primary key fields are allowed without an explicit index
      parse(%raw(`{id: {_eq: 1}}`)),
    ]).toEqual([
      [Eq({fieldName: "score", fieldValue: v(1)})],
      [Gt({fieldName: "score", fieldValue: v(1)})],
      [Lt({fieldName: "score", fieldValue: v(1)})],
      [Eq({fieldName: "score", fieldValue: v(1)}), Gt({fieldName: "score", fieldValue: v(1)})],
      [Eq({fieldName: "score", fieldValue: v(1)}), Lt({fieldName: "score", fieldValue: v(1)})],
      [Eq({fieldName: "score", fieldValue: v(1)}), Eq({fieldName: "score", fieldValue: v(2)})],
      [],
      [Eq({fieldName: "owner_id", fieldValue: v(1)})],
      [Eq({fieldName: "id", fieldValue: v(1)})],
    ])
  })

  it("Combines multiple operators and fields into a cross product of And filters", t => {
    t.expect([
      parse(%raw(`{score: {_gt: 1, _lt: 5}}`)),
      parse(%raw(`{score: {_eq: 1}, owner_id: {_eq: 2}}`)),
      parse(%raw(`{score: {_gte: 1}, owner_id: {_eq: 2}}`)),
      parse(%raw(`{score: {_in: [1, 2]}, owner_id: {_eq: 3}}`)),
      parse(%raw(`{score: {_in: []}, owner_id: {_eq: 3}}`)),
    ]).toEqual([
      [
        And({
          filters: [
            Gt({fieldName: "score", fieldValue: v(1)}),
            Lt({fieldName: "score", fieldValue: v(5)}),
          ],
        }),
      ],
      [
        And({
          filters: [
            Eq({fieldName: "score", fieldValue: v(1)}),
            Eq({fieldName: "owner_id", fieldValue: v(2)}),
          ],
        }),
      ],
      [
        And({
          filters: [
            Eq({fieldName: "score", fieldValue: v(1)}),
            Eq({fieldName: "owner_id", fieldValue: v(2)}),
          ],
        }),
        And({
          filters: [
            Gt({fieldName: "score", fieldValue: v(1)}),
            Eq({fieldName: "owner_id", fieldValue: v(2)}),
          ],
        }),
      ],
      [
        And({
          filters: [
            Eq({fieldName: "score", fieldValue: v(1)}),
            Eq({fieldName: "owner_id", fieldValue: v(3)}),
          ],
        }),
        And({
          filters: [
            Eq({fieldName: "score", fieldValue: v(2)}),
            Eq({fieldName: "owner_id", fieldValue: v(3)}),
          ],
        }),
      ],
      [],
    ])
  })

  it("Throws a user friendly error for every invalid filter", t => {
    let getError = (filter: 'a) =>
      try {
        let _ = parse(filter)
        "Expected parseGetWhereOrThrow to throw"
      } catch {
      | JsExn(e) => e->JsExn.message->Option.getOr("(no message)")
      }

    t.expect([
      getError(%raw(`{}`)),
      getError(%raw(`{score: {_eq: 1}, name: {_eq: "a"}}`)),
      getError(%raw(`{score: undefined}`)),
      getError(%raw(`{score: null}`)),
      getError(%raw(`{score: 5}`)),
      getError(%raw(`{score: "abc"}`)),
      getError(%raw(`{score: [1]}`)),
      getError(%raw(`{score: {}}`)),
      getError(%raw(`{score: {_foo: 1}}`)),
      getError(%raw(`{nonExistingField: {_eq: 1}}`)),
      getError(%raw(`{tokens: {_eq: 1}}`)),
      getError(%raw(`{name: {_eq: "a"}}`)),
      getError(%raw(`{score: {_eq: undefined}}`)),
      getError(%raw(`{score: {_eq: null}}`)),
      getError(%raw(`{score: {_in: [1, undefined]}}`)),
      getError(%raw(`{score: {_in: 5}}`)),
    ]).toEqual([
      `Empty filter passed to context.User.getWhere(). Please provide a filter like { fieldName: { _eq: value } }.`,
      `The field "name" on entity "User" does not have an index. To use it in getWhere(), add the @index directive in your schema.graphql:\n\n  name: ... @index\n\nThen run 'pnpm envio codegen' to regenerate.`,
      `Invalid undefined value passed to context.User.getWhere({ score: undefined }). Filtering by null or undefined values is not supported in getWhere. Please provide an operator like { _eq: value }.`,
      `Invalid null value passed to context.User.getWhere({ score: null }). Filtering by null or undefined values is not supported in getWhere. Please provide an operator like { _eq: value }.`,
      `Invalid value passed to context.User.getWhere({ score: ... }). Please provide an operator like { _eq: value }.`,
      `Invalid value passed to context.User.getWhere({ score: ... }). Please provide an operator like { _eq: value }.`,
      `Invalid value passed to context.User.getWhere({ score: ... }). Please provide an operator like { _eq: value }.`,
      `Empty operator passed to context.User.getWhere({ score: {} }). Please provide an operator like { _eq: value }, { _gt: value }, { _lt: value }, { _gte: value }, { _lte: value }, or { _in: [values] }.`,
      `Invalid operator "_foo" in context.User.getWhere({ score: { _foo: ... } }). Valid operators are _eq, _gt, _lt, _gte, _lte, _in.`,
      `Invalid field "nonExistingField" in context.User.getWhere(). The field doesn't exist. Rerun 'pnpm dev' to update generated code after schema.graphql changes.`,
      `The field "tokens" on entity "User" is a derived field and cannot be used in getWhere(). Use the source entity's indexed field instead.`,
      `The field "name" on entity "User" does not have an index. To use it in getWhere(), add the @index directive in your schema.graphql:\n\n  name: ... @index\n\nThen run 'pnpm envio codegen' to regenerate.`,
      `Invalid undefined value passed to context.User.getWhere({ score: { _eq: undefined } }). Filtering by null or undefined values is not supported in getWhere.`,
      `Invalid null value passed to context.User.getWhere({ score: { _eq: null } }). Filtering by null or undefined values is not supported in getWhere.`,
      `Invalid undefined value passed to context.User.getWhere({ score: { _in: [...] } }). Filtering by null or undefined values is not supported in getWhere. The undefined value is at index 1 of the _in array.`,
      `Invalid value passed to context.User.getWhere({ score: { _in: ... } }). The _in operator expects an array of values.`,
    ])
  })
})

describe("EntityFilter.getParams", () => {
  it("Reports a top-level In flat and a nested In as a single placeholder value", t => {
    let v = i => i->(Utils.magic: int => unknown)
    t.expect((
      EntityFilter.Eq({fieldName: "a", fieldValue: v(1)})->EntityFilter.getParams,
      EntityFilter.Gt({fieldName: "a", fieldValue: v(1)})->EntityFilter.getParams,
      EntityFilter.In({fieldName: "a", fieldValue: [v(1), v(2)]})->EntityFilter.getParams,
      EntityFilter.And({
        filters: [
          Gt({fieldName: "a", fieldValue: v(1)}),
          Lt({fieldName: "b", fieldValue: v(2)}),
          In({fieldName: "c", fieldValue: [v(3), v(4)]}),
        ],
      })->EntityFilter.getParams,
    )).toEqual((
      [v(1)],
      [v(1)],
      [v(1), v(2)],
      [v(1), v(2), [3, 4]->(Utils.magic: array<int> => unknown)],
    ))
  })
})

describe("EntityFilter.merge", () => {
  it("Merges Eq and In batches into a single In, keeps the rest as is", t => {
    let v = i => i->(Utils.magic: int => unknown)
    t.expect(
      (
        [
          EntityFilter.Eq({fieldName: "a", fieldValue: v(1)}),
          EntityFilter.Eq({fieldName: "a", fieldValue: v(2)}),
        ]->EntityFilter.merge,
        [
          EntityFilter.In({fieldName: "a", fieldValue: [v(1), v(2)]}),
          EntityFilter.In({fieldName: "a", fieldValue: [v(3)]}),
        ]->EntityFilter.merge,
        [
          EntityFilter.Gt({fieldName: "a", fieldValue: v(1)}),
          EntityFilter.Gt({fieldName: "a", fieldValue: v(2)}),
        ]->EntityFilter.merge,
        [EntityFilter.Eq({fieldName: "a", fieldValue: v(1)})]->EntityFilter.merge,
        []->EntityFilter.merge,
      ),
    ).toEqual((
      [EntityFilter.In({fieldName: "a", fieldValue: [v(1), v(2)]})],
      [EntityFilter.In({fieldName: "a", fieldValue: [v(1), v(2), v(3)]})],
      [
        EntityFilter.Gt({fieldName: "a", fieldValue: v(1)}),
        EntityFilter.Gt({fieldName: "a", fieldValue: v(2)}),
      ],
      [EntityFilter.Eq({fieldName: "a", fieldValue: v(1)})],
      [],
    ))
  })

  it("Throws on a mismatched filter instead of silently dropping it", t => {
    let v = i => i->(Utils.magic: int => unknown)
    t.expect(() =>
      [
        EntityFilter.Eq({fieldName: "a", fieldValue: v(1)}),
        EntityFilter.And({filters: [EntityFilter.Eq({fieldName: "a", fieldValue: v(2)})]}),
      ]->EntityFilter.merge
    ).toThrowError(
      "Unexpected filter And(a:Eq:2) in a merged batch. Filters batched into a single query must use the same operator and field.",
    )
  })
})

describe("EntityFilter.makeMatcher", () => {
  let table = Table.mkTable(
    "users",
    ~fields=[
      Table.mkField("id", String, ~isPrimaryKey=true, ~fieldSchema=S.string),
      Table.mkField("score", Int32, ~isIndex=true, ~fieldSchema=S.string),
      Table.mkField("balance", BigInt({}), ~isIndex=true, ~fieldSchema=S.string),
      Table.mkField("active", Boolean, ~isIndex=true, ~fieldSchema=S.string),
      Table.mkField("nickname", String, ~isIndex=true, ~isNullable=true, ~fieldSchema=S.string),
      Table.mkField("price", BigDecimal({}), ~isIndex=true, ~fieldSchema=S.string),
      Table.mkField("tags", String, ~isArray=true, ~isIndex=true, ~fieldSchema=S.string),
      Table.mkField("created", Date, ~isIndex=true, ~fieldSchema=S.string),
    ],
  )

  let u = value => value->toUnknown

  let mkEntity = (~score, ~balance, ~active, ~nickname, ~price, ~tags, ~created) => {
    let entity = Dict.make()
    entity->Dict.set("id", "id"->u)
    entity->Dict.set("score", score->u)
    entity->Dict.set("balance", balance->u)
    entity->Dict.set("active", active->u)
    entity->Dict.set("price", price->u)
    entity->Dict.set("tags", tags->u)
    entity->Dict.set("created", created->u)
    switch nickname {
    | Some(nickname) => entity->Dict.set("nickname", nickname->u)
    | None => ()
    }
    entity->asEntity
  }

  // Columns chosen so each filter below partitions the three rows distinctly.
  let entities = [
    mkEntity(
      ~score=5,
      ~balance=BigInt.fromInt(10),
      ~active=true,
      ~nickname=Some("nick"),
      ~price=BigDecimal.fromInt(3),
      ~tags=["x", "y"],
      ~created=Date.fromTime(1000.),
    ),
    mkEntity(
      ~score=7,
      ~balance=BigInt.fromInt(20),
      ~active=false,
      ~nickname=Some("zzz"),
      ~price=BigDecimal.fromInt(5),
      ~tags=["x"],
      ~created=Date.fromTime(2000.),
    ),
    mkEntity(
      ~score=2,
      ~balance=BigInt.fromInt(5),
      ~active=true,
      ~nickname=None,
      ~price=BigDecimal.fromInt(1),
      ~tags=["x", "y"],
      ~created=Date.fromTime(500.),
    ),
  ]

  // Each case pairs a filter with its expected match per entity above.
  let cases: array<(EntityFilter.t, array<bool>)> = [
    (Eq({fieldName: "score", fieldValue: u(5)}), [true, false, false]),
    (Gt({fieldName: "score", fieldValue: u(5)}), [false, true, false]),
    (Lt({fieldName: "score", fieldValue: u(5)}), [false, false, true]),
    (In({fieldName: "score", fieldValue: [u(5), u(7)]}), [true, true, false]),
    (Eq({fieldName: "balance", fieldValue: u(BigInt.fromInt(10))}), [true, false, false]),
    (Gt({fieldName: "balance", fieldValue: u(BigInt.fromInt(10))}), [false, true, false]),
    (Eq({fieldName: "active", fieldValue: u(true)}), [true, false, true]),
    (Eq({fieldName: "nickname", fieldValue: u("nick")}), [true, false, false]),
    // The undefined nullable column matches no comparison.
    (Gt({fieldName: "nickname", fieldValue: u("a")}), [true, true, false]),
    (In({fieldName: "nickname", fieldValue: [u("nick"), u("other")]}), [true, false, false]),
    (Eq({fieldName: "price", fieldValue: u(BigDecimal.fromInt(3))}), [true, false, false]),
    (Gt({fieldName: "price", fieldValue: u(BigDecimal.fromInt(3))}), [false, true, false]),
    (Eq({fieldName: "tags", fieldValue: u(["x", "y"])}), [true, false, true]),
    // Lexicographic: ["x"] is a proper prefix of ["x","y"], so it sorts lower.
    (Lt({fieldName: "tags", fieldValue: u(["x", "y"])}), [false, true, false]),
    (Eq({fieldName: "created", fieldValue: u(Date.fromTime(1000.))}), [true, false, false]),
    (Gt({fieldName: "created", fieldValue: u(Date.fromTime(1000.))}), [false, true, false]),
    (
      And({
        filters: [
          Gt({fieldName: "score", fieldValue: u(3)}),
          Eq({fieldName: "active", fieldValue: u(true)}),
        ],
      }),
      [true, false, false],
    ),
  ]

  it("Specializes the comparison per field type for every operator", t => {
    let actual = cases->Array.map(((filter, _expected)) => {
      let matcher = filter->EntityFilter.makeMatcher(~table)
      entities->Array.map(entity => matcher(entity))
    })
    t.expect(actual).toEqual(cases->Array.map(((_filter, expected)) => expected))
  })

  it("Treats a nullish value on an object-typed field as matching nothing", t => {
    // Without the nullish guard these would call BigDecimal/Date/Json methods
    // on undefined and throw rather than return false.
    let nullableTable = Table.mkTable(
      "t",
      ~fields=[
        Table.mkField("id", String, ~isPrimaryKey=true, ~fieldSchema=S.string),
        Table.mkField("price", BigDecimal({}), ~isIndex=true, ~isNullable=true, ~fieldSchema=S.string),
        Table.mkField("created", Date, ~isIndex=true, ~isNullable=true, ~fieldSchema=S.string),
        Table.mkField("tags", String, ~isArray=true, ~isIndex=true, ~isNullable=true, ~fieldSchema=S.string),
      ],
    )
    let entity = Dict.make()
    entity->Dict.set("id", "x"->u)
    let run = filter => (filter->EntityFilter.makeMatcher(~table=nullableTable))(entity->asEntity)
    t.expect([
      run(Eq({fieldName: "price", fieldValue: u(BigDecimal.fromInt(1))})),
      run(Gt({fieldName: "price", fieldValue: u(BigDecimal.fromInt(1))})),
      run(Eq({fieldName: "created", fieldValue: u(Date.fromTime(0.))})),
      run(Eq({fieldName: "tags", fieldValue: u(["x"])})),
    ]).toEqual([false, false, false, false])
  })

  it("Compares Json fields structurally rather than by reference", t => {
    let jsonTable = Table.mkTable(
      "t",
      ~fields=[
        Table.mkField("id", String, ~isPrimaryKey=true, ~fieldSchema=S.string),
        Table.mkField("meta", Json, ~isIndex=true, ~fieldSchema=S.string),
      ],
    )
    let entity = Dict.make()
    entity->Dict.set("id", "x"->u)
    entity->Dict.set("meta", {"a": 1, "b": [2, 3]}->u)
    let run = value =>
      (Eq({fieldName: "meta", fieldValue: value->u})->EntityFilter.makeMatcher(~table=jsonTable))(
        entity->asEntity,
      )
    t.expect([
      // A distinct object with equal contents matches; a differing one does not.
      run({"a": 1, "b": [2, 3]}),
      run({"a": 1, "b": [2, 4]}),
    ]).toEqual([true, false])
  })

  it("Throws when an And filter has no nested filters", t => {
    let matcher = EntityFilter.And({filters: []})->EntityFilter.makeMatcher(~table)
    t.expect(() => matcher(Dict.make()->asEntity)).toThrowError(
      `The "and" filter must contain at least one nested filter.`,
    )
  })
})

describe("EntityFilter.toString", () => {
  let u = value => value->toUnknown

  it("Serializes each value type into a stable, unambiguous cache key", t => {
    t.expect(
      [
        EntityFilter.Eq({fieldName: "a", fieldValue: u("hello")}),
        EntityFilter.Eq({fieldName: "a", fieldValue: u(5)}),
        EntityFilter.Eq({fieldName: "a", fieldValue: u(BigInt.fromInt(10))}),
        EntityFilter.Eq({fieldName: "a", fieldValue: u(true)}),
        EntityFilter.Eq({fieldName: "a", fieldValue: u(BigDecimal.fromFloat(1.5))}),
        EntityFilter.Gt({fieldName: "a", fieldValue: u(5)}),
        EntityFilter.Lt({fieldName: "a", fieldValue: u(5)}),
        EntityFilter.In({fieldName: "a", fieldValue: [u(1), u(2)]}),
        EntityFilter.Eq({fieldName: "a", fieldValue: u(["x", "y"])}),
        EntityFilter.And({
          filters: [
            Gt({fieldName: "a", fieldValue: u(1)}),
            Lt({fieldName: "b", fieldValue: u(2)}),
          ],
        }),
      ]->Array.map(EntityFilter.toString),
    ).toEqual([
      "a:Eq:hello",
      "a:Eq:5",
      "a:Eq:10",
      "a:Eq:true",
      "a:Eq:1.5",
      "a:Gt:5",
      "a:Lt:5",
      "a:In:[1,2]",
      "a:Eq:[x,y]",
      "And(a:Gt:1,b:Lt:2)",
    ])
  })
})

describe("EntityFilter.mapValues", () => {
  it("Maps scalar values one by one and In values as a whole array", t => {
    let calls = []
    let mapped =
      EntityFilter.And({
        filters: [
          Eq({fieldName: "a", fieldValue: 1->(Utils.magic: int => unknown)}),
          In({fieldName: "b", fieldValue: [2, 3]->(Utils.magic: array<int> => array<unknown>)}),
        ],
      })->EntityFilter.mapValues(~mapValue=(~fieldName, ~fieldValue, ~isArray) => {
        calls->Array.push((fieldName, isArray))->ignore
        isArray
          ? fieldValue
            ->(Utils.magic: unknown => array<int>)
            ->Array.map(v => v * 10)
            ->(Utils.magic: array<int> => unknown)
          : (fieldValue->(Utils.magic: unknown => int) * 10)->(Utils.magic: int => unknown)
      })

    t.expect((mapped, calls)).toEqual((
      EntityFilter.And({
        filters: [
          Eq({fieldName: "a", fieldValue: 10->(Utils.magic: int => unknown)}),
          In({fieldName: "b", fieldValue: [20, 30]->(Utils.magic: array<int> => array<unknown>)}),
        ],
      }),
      [("a", false), ("b", true)],
    ))
  })
})
