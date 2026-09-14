open Vitest

external toUnknown: 'a => unknown = "%identity"
external asEntity: dict<unknown> => Internal.entity = "%identity"

describe("EntityFilter.toOperationKey", () => {
  it("Replaces filter values with $N placeholders", t => {
    let v = 0->(Utils.magic: int => unknown)
    t.expect(
      [
        dict{"a": dict{"_eq": v}},
        dict{"a": dict{"_gt": v}},
        dict{"a": dict{"_lt": v}},
        dict{"a": dict{"_in": v}},
        dict{"a": dict{"_gt": v}, "b": dict{"_lt": v}},
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

describe("EntityFilter.validateOrThrow", () => {
  let table = Table.mkTable(
    "users",
    ~fields=[
      Table.mkField("id", String, ~isPrimaryKey=true, ~fieldSchema=S.string),
      Table.mkField("score", Int32, ~isIndex=true, ~fieldSchema=S.int),
      Table.mkField("name", String, ~fieldSchema=S.string),
      Table.mkField("owner", String, ~linkedEntity="Owner", ~fieldSchema=S.string),
      Table.mkField("createdAt", Date, ~isIndex=true, ~fieldSchema=S.string),
      Table.mkField("tag", Bytea, ~isIndex=true, ~fieldSchema=S.string),
      Table.mkDerivedFromField("tokens", ~derivedFromEntity="Token", ~derivedFromField="owner"),
    ],
  )

  // The filter comes from user-land JS, so test inputs are raw objects
  let parse = (filter: 'a) =>
    filter
    ->(Utils.magic: 'a => EntityFilter.t)
    ->EntityFilter.validateOrThrow(~entityName="User", ~table)

  it("Accepts every operator and every non-derived field", t => {
    let accepts = (filter: 'a) =>
      switch try Ok(parse(filter)) catch {
      | JsExn(e) => Error(e->JsExn.message->Option.getOr("(no message)"))
      } {
      | Ok() => "ok"
      | Error(message) => message
      }

    t.expect([
      accepts(%raw(`{score: {_eq: 1}}`)),
      accepts(%raw(`{score: {_gt: 1}}`)),
      accepts(%raw(`{score: {_lt: 1}}`)),
      accepts(%raw(`{score: {_gte: 1}}`)),
      accepts(%raw(`{score: {_lte: 1}}`)),
      accepts(%raw(`{score: {_in: [1, 2]}}`)),
      accepts(%raw(`{score: {_in: []}}`)),
      accepts(%raw(`{score: {_gt: 1, _lt: 5}}`)),
      accepts(%raw(`{score: {_eq: 1}, owner_id: {_eq: 2}}`)),
      // Unindexed linked entity fields are allowed via the _id api name
      accepts(%raw(`{owner_id: {_eq: 1}}`)),
      // Primary key fields are allowed without an explicit index
      accepts(%raw(`{id: {_eq: 1}}`)),
      // Any non-derived field is allowed — the index is created on demand
      accepts(%raw(`{name: {_eq: 1}}`)),
    ]).toEqual(["ok", "ok", "ok", "ok", "ok", "ok", "ok", "ok", "ok", "ok", "ok", "ok"])
  })

  it("Throws a user friendly error for every invalid filter", t => {
    let getError = (filter: 'a) =>
      try {
        parse(filter)
        "Expected validateOrThrow to throw"
      } catch {
      | JsExn(e) => e->JsExn.message->Option.getOr("(no message)")
      }

    t.expect([
      getError(%raw(`{}`)),
      getError(%raw(`{score: undefined}`)),
      getError(%raw(`{score: null}`)),
      getError(%raw(`{score: 5}`)),
      getError(%raw(`{score: "abc"}`)),
      getError(%raw(`{score: [1]}`)),
      getError(%raw(`{score: {}}`)),
      getError(%raw(`{score: {_foo: 1}}`)),
      getError(%raw(`{nonExistingField: {_eq: 1}}`)),
      getError(%raw(`{tokens: {_eq: 1}}`)),
      getError(%raw(`{score: {_eq: undefined}}`)),
      getError(%raw(`{score: {_eq: null}}`)),
      getError(%raw(`{score: {_in: [1, undefined]}}`)),
      getError(%raw(`{score: {_in: 5}}`)),
      // A comparison that needs a specific object shape rejects the value here
      // instead of throwing out of the comparator.
      getError(%raw(`{createdAt: {_eq: "2020-01-01"}}`)),
      getError(%raw(`{createdAt: {_in: [new Date(0), 1700000000]}}`)),
      getError(%raw(`{tag: {_eq: "0xdeadbeef"}}`)),
    ]).toEqual([
      `Empty filter passed to context.User.getWhere(). Please provide a filter like { fieldName: { _eq: value } }.`,
      `Invalid undefined value passed to context.User.getWhere({ score: undefined }). Filtering by null or undefined values is not supported in getWhere. Please provide an operator like { _eq: value }.`,
      `Invalid null value passed to context.User.getWhere({ score: null }). Filtering by null or undefined values is not supported in getWhere. Please provide an operator like { _eq: value }.`,
      `Invalid value passed to context.User.getWhere({ score: ... }). Please provide an operator like { _eq: value }.`,
      `Invalid value passed to context.User.getWhere({ score: ... }). Please provide an operator like { _eq: value }.`,
      `Invalid value passed to context.User.getWhere({ score: ... }). Please provide an operator like { _eq: value }.`,
      `Empty operator passed to context.User.getWhere({ score: {} }). Please provide an operator like { _eq: value }, { _gt: value }, { _lt: value }, { _gte: value }, { _lte: value }, or { _in: [values] }.`,
      `Invalid operator "_foo" in context.User.getWhere({ score: { _foo: ... } }). Valid operators are _eq, _gt, _lt, _gte, _lte, _in.`,
      `Invalid field "nonExistingField" in context.User.getWhere(). The field doesn't exist. Rerun 'pnpm dev' to update generated code after schema.graphql changes.`,
      `The field "tokens" on entity "User" is a derived field and cannot be used in getWhere(). Use the source entity's indexed field instead.`,
      `Invalid undefined value passed to context.User.getWhere({ score: { _eq: undefined } }). Filtering by null or undefined values is not supported in getWhere.`,
      `Invalid null value passed to context.User.getWhere({ score: { _eq: null } }). Filtering by null or undefined values is not supported in getWhere.`,
      `Invalid undefined value passed to context.User.getWhere({ score: { _in: [...] } }). Filtering by null or undefined values is not supported in getWhere. The undefined value is at index 1 of the _in array.`,
      `Invalid value passed to context.User.getWhere({ score: { _in: ... } }). The _in operator expects an array of values.`,
      `Invalid value passed to context.User.getWhere({ createdAt: { _eq: ... } }). The field "createdAt" expects a Date.`,
      `Invalid value passed to context.User.getWhere({ createdAt: { _in: ... } }). The field "createdAt" expects a Date. The value is at index 1 of the _in array.`,
      `Invalid value passed to context.User.getWhere({ tag: { _eq: ... } }). The field "tag" expects a Uint8Array.`,
    ])
  })
})

describe("EntityFilter.getParams", () => {
  it("Reports one value per operator, in the order the query binds them", t => {
    let v = i => i->(Utils.magic: int => unknown)
    t.expect((
      Dict.fromArray([("a", Dict.fromArray([("_eq", v(1))]))])->EntityFilter.getParams,
      Dict.fromArray([("a", Dict.fromArray([("_gt", v(1))]))])->EntityFilter.getParams,
      Dict.fromArray([
        ("a", Dict.fromArray([("_in", [v(1), v(2)]->(Utils.magic: array<unknown> => unknown))])),
      ])->EntityFilter.getParams,
      Dict.fromArray([
        ("a", Dict.fromArray([("_gt", v(1))])),
        ("b", Dict.fromArray([("_lt", v(2))])),
        ("c", Dict.fromArray([("_in", [v(3), v(4)]->(Utils.magic: array<unknown> => unknown))])),
      ])->EntityFilter.getParams,
    )).toEqual((
      [v(1)],
      [v(1)],
      [[1, 2]->(Utils.magic: array<int> => unknown)],
      [v(1), v(2), [3, 4]->(Utils.magic: array<int> => unknown)],
    ))
  })
})

describe("EntityFilter.merge", () => {
  it("Merges Eq and In batches into a single In, keeps the rest as is", t => {
    let v = i => i->(Utils.magic: int => unknown)
    t.expect((
      [
        Dict.fromArray([("a", Dict.fromArray([("_eq", v(1))]))]),
        Dict.fromArray([("a", Dict.fromArray([("_eq", v(2))]))]),
      ]->EntityFilter.merge,
      [
        Dict.fromArray([
          ("a", Dict.fromArray([("_in", [v(1), v(2)]->(Utils.magic: array<unknown> => unknown))])),
        ]),
        Dict.fromArray([
          ("a", Dict.fromArray([("_in", [v(3)]->(Utils.magic: array<unknown> => unknown))])),
        ]),
      ]->EntityFilter.merge,
      [
        Dict.fromArray([("a", Dict.fromArray([("_gt", v(1))]))]),
        Dict.fromArray([("a", Dict.fromArray([("_gt", v(2))]))]),
      ]->EntityFilter.merge,
      [Dict.fromArray([("a", Dict.fromArray([("_eq", v(1))]))])]->EntityFilter.merge,
      []->EntityFilter.merge,
    )).toEqual((
      [
        Dict.fromArray([
          ("a", Dict.fromArray([("_in", [v(1), v(2)]->(Utils.magic: array<unknown> => unknown))])),
        ]),
      ],
      [
        Dict.fromArray([
          (
            "a",
            Dict.fromArray([("_in", [v(1), v(2), v(3)]->(Utils.magic: array<unknown> => unknown))]),
          ),
        ]),
      ],
      [
        Dict.fromArray([("a", Dict.fromArray([("_gt", v(1))]))]),
        Dict.fromArray([("a", Dict.fromArray([("_gt", v(2))]))]),
      ],
      [Dict.fromArray([("a", Dict.fromArray([("_eq", v(1))]))])],
      [],
    ))
  })

  it("Throws on a mismatched filter instead of silently dropping it", t => {
    let v = i => i->(Utils.magic: int => unknown)
    t->toThrowErrorEqual(
      () =>
        [
          Dict.fromArray([("a", Dict.fromArray([("_eq", v(1))]))]),
          Dict.fromArray([
            ("a", Dict.fromArray([("_eq", v(2))])),
            ("b", Dict.fromArray([("_eq", v(3))])),
          ]),
        ]->EntityFilter.merge,
      "Unexpected composite filter in a merged batch. Filters batched into a single query must use the same operator and field.",
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
    (dict{"score": dict{"_eq": u(5)}}, [true, false, false]),
    (dict{"score": dict{"_gt": u(5)}}, [false, true, false]),
    (dict{"score": dict{"_lt": u(5)}}, [false, false, true]),
    (dict{"score": dict{"_gte": u(5)}}, [true, true, false]),
    (dict{"score": dict{"_lte": u(5)}}, [true, false, true]),
    (dict{"score": dict{"_in": u([5, 7])}}, [true, true, false]),
    (dict{"balance": dict{"_eq": u(BigInt.fromInt(10))}}, [true, false, false]),
    (dict{"balance": dict{"_gt": u(BigInt.fromInt(10))}}, [false, true, false]),
    (dict{"active": dict{"_eq": u(true)}}, [true, false, true]),
    (dict{"nickname": dict{"_eq": u("nick")}}, [true, false, false]),
    // The undefined nullable column matches no comparison.
    (dict{"nickname": dict{"_gt": u("a")}}, [true, true, false]),
    (dict{"nickname": dict{"_in": u(["nick", "other"])}}, [true, false, false]),
    (dict{"price": dict{"_eq": u(BigDecimal.fromInt(3))}}, [true, false, false]),
    (dict{"price": dict{"_gt": u(BigDecimal.fromInt(3))}}, [false, true, false]),
    (dict{"tags": dict{"_eq": u(["x", "y"])}}, [true, false, true]),
    // Lexicographic: ["x"] is a proper prefix of ["x","y"], so it sorts lower.
    (dict{"tags": dict{"_lt": u(["x", "y"])}}, [false, true, false]),
    (dict{"created": dict{"_eq": u(Date.fromTime(1000.))}}, [true, false, false]),
    (dict{"created": dict{"_gt": u(Date.fromTime(1000.))}}, [false, true, false]),
    // Every field in the filter must match, and a mismatch on the first one
    // skips the rest.
    (dict{"score": dict{"_gt": u(3)}, "active": dict{"_eq": u(true)}}, [true, false, false]),
    // Two operators on one field are both applied.
    (dict{"score": dict{"_gt": u(2), "_lt": u(7)}}, [true, false, false]),
  ]

  it("Specializes the comparison per field type for every operator", t => {
    let actual = cases->Array.map(
      ((filter, _expected)) => {
        let matcher = filter->EntityFilter.makeMatcher(~table)
        entities->Array.map(entity => matcher(entity))
      },
    )
    t.expect(actual).toEqual(cases->Array.map(((_filter, expected)) => expected))
  })

  it("Treats a nullish value on an object-typed field as matching nothing", t => {
    // Without the nullish guard these would call BigDecimal/Date/Json methods
    // on undefined and throw rather than return false.
    let nullableTable = Table.mkTable(
      "t",
      ~fields=[
        Table.mkField("id", String, ~isPrimaryKey=true, ~fieldSchema=S.string),
        Table.mkField(
          "price",
          BigDecimal({}),
          ~isIndex=true,
          ~isNullable=true,
          ~fieldSchema=S.string,
        ),
        Table.mkField("created", Date, ~isIndex=true, ~isNullable=true, ~fieldSchema=S.string),
        Table.mkField(
          "tags",
          String,
          ~isArray=true,
          ~isIndex=true,
          ~isNullable=true,
          ~fieldSchema=S.string,
        ),
      ],
    )
    let entity = Dict.make()
    entity->Dict.set("id", "x"->u)
    let run = filter => (filter->EntityFilter.makeMatcher(~table=nullableTable))(entity->asEntity)
    t.expect([
      run(dict{"price": dict{"_eq": u(BigDecimal.fromInt(1))}}),
      run(dict{"price": dict{"_gt": u(BigDecimal.fromInt(1))}}),
      run(dict{"created": dict{"_eq": u(Date.fromTime(0.))}}),
      run(dict{"tags": dict{"_eq": u(["x"])}}),
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
      (dict{"meta": dict{"_eq": value->u}}->EntityFilter.makeMatcher(~table=jsonTable))(
        entity->asEntity,
      )
    t.expect([
      // A distinct object with equal contents matches; a differing one does not.
      run({"a": 1, "b": [2, 3]}),
      run({"a": 1, "b": [2, 4]}),
    ]).toEqual([true, false])
  })

  it("Matches everything when the filter constrains no field", t => {
    let matcher = Dict.make()->EntityFilter.makeMatcher(~table)
    t.expect(matcher(Dict.make()->asEntity)).toEqual(true)
  })
})

describe("EntityFilter.toString", () => {
  let u = value => value->toUnknown

  it("Serializes each value type into a stable, unambiguous cache key", t => {
    t.expect(
      [
        dict{"a": dict{"_eq": u("hello")}},
        dict{"a": dict{"_eq": u(5)}},
        dict{"a": dict{"_eq": u(BigInt.fromInt(10))}},
        dict{"a": dict{"_eq": u(true)}},
        dict{"a": dict{"_eq": u(BigDecimal.fromFloat(1.5))}},
        dict{"a": dict{"_gt": u(5)}},
        dict{"a": dict{"_lt": u(5)}},
        dict{"a": dict{"_in": u([1, 2])}},
        dict{"a": dict{"_eq": u(["x", "y"])}},
        dict{"a": dict{"_gt": u(1)}, "b": dict{"_lt": u(2)}},
      ]->Array.map(EntityFilter.toString),
    ).toEqual([
      `a_eq"hello"`,
      "a_eq5",
      "a_eq10",
      "a_eqtrue",
      `a_eq"1.5"`,
      "a_gt5",
      "a_lt5",
      "a_in[1,2]",
      `a_eq["x","y"]`,
      "a_gt1b_lt2",
    ])
  })

  it("Keeps values apart that a toString-based key collapsed onto one", t => {
    t.expect(
      [
        // Sub-second instants: Date.prototype.toString stops at seconds.
        dict{"a": dict{"_eq": u(Date.fromTime(1000.))}},
        dict{"a": dict{"_eq": u(Date.fromTime(1500.))}},
        // Any object stringifies to "[object Object]".
        dict{"a": dict{"_eq": u({"x": 1})}},
        dict{"a": dict{"_eq": u({"x": 2})}},
        // A separator inside a string could imitate the element separator.
        dict{"a": dict{"_eq": u(["x,y"])}},
        dict{"a": dict{"_eq": u(["x", "y"])}},
      ]->Array.map(EntityFilter.toString),
    ).toEqual([
      `a_eq"1970-01-01T00:00:01.000Z"`,
      `a_eq"1970-01-01T00:00:01.500Z"`,
      `a_eq{"x":1}`,
      `a_eq{"x":2}`,
      `a_eq["x,y"]`,
      `a_eq["x","y"]`,
    ])
  })
})
