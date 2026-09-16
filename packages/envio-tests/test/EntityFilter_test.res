open Vitest

external toUnknown: 'a => unknown = "%identity"
external asEntity: dict<unknown> => Internal.entity = "%identity"

// A filter only exists once it has been parsed against its table, so every
// case below goes through the same entry point a handler's getWhere does.
let parse = (filter, ~table) => filter->EntityFilter.parseOrThrow(~entityName="User", ~table)

// Three plain columns for the cases that are about the filter's shape rather
// than its column types.
let abcTable = Table.mkTable(
  "users",
  ~fields=[
    Table.mkField("id", String, ~isPrimaryKey=true, ~fieldSchema=S.string),
    Table.mkField("a", Int32, ~isIndex=true, ~fieldSchema=S.int),
    Table.mkField("b", Int32, ~isIndex=true, ~fieldSchema=S.int),
    Table.mkField("c", Int32, ~isIndex=true, ~fieldSchema=S.int),
  ],
)

describe("EntityFilter.toOperationKey", () => {
  it("Replaces filter values with $N placeholders", t => {
    let v = 0->(Utils.magic: int => unknown)
    let f = filter => filter->parse(~table=abcTable)
    t.expect(
      [
        f(dict{"a": dict{"_eq": v}}),
        f(dict{"a": dict{"_gt": v}}),
        f(dict{"a": dict{"_lt": v}}),
        f(dict{"a": dict{"_in": [v]->toUnknown}}),
        f(dict{"a": dict{"_gt": v}, "b": dict{"_lt": v}}),
        // Operators on one field stay under that field, rather than repeating
        // the key — the printed form is what the user sees in an error log.
        f(dict{"a": dict{"_gt": v, "_lt": v}}),
        f(dict{"a": dict{"_gt": v, "_eq": v}}),
      ]->Array.map(filter => filter->EntityFilter.toOperationKey(~entityName="User")),
    ).toEqual([
      "User.getWhere({a: $1})",
      "User.getWhere({a: {_gt: $1}})",
      "User.getWhere({a: {_lt: $1}})",
      "User.getWhere({a: {_in: $1}})",
      "User.getWhere({a: {_gt: $1}, b: {_lt: $2}})",
      "User.getWhere({a: {_gt: $1, _lt: $2}})",
      "User.getWhere({a: {_gt: $1, _eq: $2}})",
    ])
  })
})

describe("EntityFilter.parseOrThrow", () => {
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
  let parse = (filter: 'a) => filter->(Utils.magic: 'a => dict<dict<unknown>>)->parse(~table)

  it("Accepts every operator and every non-derived field", t => {
    let accepts = (filter: 'a) =>
      switch try Ok(parse(filter)) catch {
      | JsExn(e) => Error(e->JsExn.message->Option.getOr("(no message)"))
      } {
      | Ok(_) => "ok"
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
        let _ = parse(filter)
        "Expected parseOrThrow to throw"
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
      // The cache key has to render every value it is handed.
      getError(%raw(`{name: {_eq: {a: 1n}}}`)),
      getError(%raw(`{name: {_in: [{ok: 1}, {a: 1n}]}}`)),
      getError(
        %raw(`(() => { const circular = {}; circular.self = circular; return {name: {_eq: circular}} })()`),
      ),
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
      `Invalid value passed to context.User.getWhere({ name: { _eq: ... } }). The value can't be serialized, so it can't be used as a filter. An object holding a bigint, or a circular reference, is not supported.`,
      `Invalid value passed to context.User.getWhere({ name: { _in: ... } }). The value can't be serialized, so it can't be used as a filter. An object holding a bigint, or a circular reference, is not supported. The value is at index 1 of the _in array.`,
      `Invalid value passed to context.User.getWhere({ name: { _eq: ... } }). The value can't be serialized, so it can't be used as a filter. An object holding a bigint, or a circular reference, is not supported.`,
    ])
  })
})

describe("EntityFilter.getParams", () => {
  it("Reports one value per operator, in the order the query binds them", t => {
    let v = i => i->(Utils.magic: int => unknown)
    let params = filter => filter->parse(~table=abcTable)->EntityFilter.getParams
    t.expect((
      dict{"a": dict{"_eq": v(1)}}->params,
      dict{"a": dict{"_gt": v(1)}}->params,
      dict{"a": dict{"_in": [v(1), v(2)]->(Utils.magic: array<unknown> => unknown)}}->params,
      dict{"a": dict{"_gt": v(1)}, "b": dict{"_lt": v(2)}, "c": dict{"_in": [v(3), v(4)]->(Utils.magic: array<unknown> => unknown)}}->params,
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
    let merge = filters =>
      filters
      ->Array.map(filter => filter->parse(~table=abcTable))
      ->EntityFilter.merge
      ->Array.map(EntityFilter.entries)
    t.expect((
      [
        dict{"a": dict{"_eq": v(1)}},
        dict{"a": dict{"_eq": v(2)}},
      ]->merge,
      [
        dict{"a": dict{"_in": [v(1), v(2)]->(Utils.magic: array<unknown> => unknown)}},
        dict{"a": dict{"_in": [v(3)]->(Utils.magic: array<unknown> => unknown)}},
      ]->merge,
      [
        dict{"a": dict{"_gt": v(1)}},
        dict{"a": dict{"_gt": v(2)}},
      ]->merge,
      [dict{"a": dict{"_eq": v(1)}}]->merge,
      []->merge,
    )).toEqual((
      [
        dict{"a": dict{"_in": [v(1), v(2)]->(Utils.magic: array<unknown> => unknown)}},
      ],
      [
        dict{"a": dict{"_in": [v(1), v(2), v(3)]->(Utils.magic: array<unknown> => unknown)}},
      ],
      [
        dict{"a": dict{"_gt": v(1)}},
        dict{"a": dict{"_gt": v(2)}},
      ],
      [dict{"a": dict{"_eq": v(1)}}],
      [],
    ))
  })

  it("Throws on a mismatched filter instead of silently dropping it", t => {
    let v = i => i->(Utils.magic: int => unknown)
    t->toThrowErrorEqual(
      () =>
        [
          dict{"a": dict{"_eq": v(1)}},
          dict{"a": dict{"_eq": v(2)}, "b": dict{"_eq": v(3)}},
        ]
        ->Array.map(filter => filter->parse(~table=abcTable))
        ->EntityFilter.merge,
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

  let f = filter => filter->parse(~table)

  // Each case pairs a filter with its expected match per entity above.
  let cases: array<(EntityFilter.t, array<bool>)> = [
    (f(dict{"score": dict{"_eq": u(5)}}), [true, false, false]),
    (f(dict{"score": dict{"_gt": u(5)}}), [false, true, false]),
    (f(dict{"score": dict{"_lt": u(5)}}), [false, false, true]),
    (f(dict{"score": dict{"_gte": u(5)}}), [true, true, false]),
    (f(dict{"score": dict{"_lte": u(5)}}), [true, false, true]),
    (f(dict{"score": dict{"_in": u([5, 7])}}), [true, true, false]),
    (f(dict{"balance": dict{"_eq": u(BigInt.fromInt(10))}}), [true, false, false]),
    (f(dict{"balance": dict{"_gt": u(BigInt.fromInt(10))}}), [false, true, false]),
    (f(dict{"active": dict{"_eq": u(true)}}), [true, false, true]),
    (f(dict{"nickname": dict{"_eq": u("nick")}}), [true, false, false]),
    // The undefined nullable column matches no comparison.
    (f(dict{"nickname": dict{"_gt": u("a")}}), [true, true, false]),
    (f(dict{"nickname": dict{"_in": u(["nick", "other"])}}), [true, false, false]),
    (f(dict{"price": dict{"_eq": u(BigDecimal.fromInt(3))}}), [true, false, false]),
    (f(dict{"price": dict{"_gt": u(BigDecimal.fromInt(3))}}), [false, true, false]),
    (f(dict{"tags": dict{"_eq": u(["x", "y"])}}), [true, false, true]),
    // Lexicographic: ["x"] is a proper prefix of ["x","y"], so it sorts lower.
    (f(dict{"tags": dict{"_lt": u(["x", "y"])}}), [false, true, false]),
    (f(dict{"created": dict{"_eq": u(Date.fromTime(1000.))}}), [true, false, false]),
    (f(dict{"created": dict{"_gt": u(Date.fromTime(1000.))}}), [false, true, false]),
    // Every field in the filter must match, and a mismatch on the first one
    // skips the rest.
    (f(dict{"score": dict{"_gt": u(3)}, "active": dict{"_eq": u(true)}}), [true, false, false]),
    // Two operators on one field are both applied.
    (f(dict{"score": dict{"_gt": u(2), "_lt": u(7)}}), [true, false, false]),
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
    let run = filter =>
      (filter->parse(~table=nullableTable)->EntityFilter.makeMatcher(~table=nullableTable))(
        entity->asEntity,
      )
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
      (
        dict{"meta": dict{"_eq": value->u}}
        ->parse(~table=jsonTable)
        ->EntityFilter.makeMatcher(~table=jsonTable)
      )(entity->asEntity)
    t.expect([
      // A distinct object with equal contents matches; a differing one does not.
      run({"a": 1, "b": [2, 3]}),
      run({"a": 1, "b": [2, 4]}),
    ]).toEqual([true, false])
  })
})

describe("EntityFilter.toString", () => {
  let u = value => value->toUnknown

  // Column types drive the key the same way they drive the matcher, so the
  // table names one field per kind the projections cover.
  let table = Table.mkTable(
    "users",
    ~fields=[
      Table.mkField("id", String, ~isPrimaryKey=true, ~fieldSchema=S.string),
      Table.mkField("a", String, ~isIndex=true, ~fieldSchema=S.string),
      Table.mkField("ab", String, ~isIndex=true, ~fieldSchema=S.string),
      Table.mkField("b", String, ~isIndex=true, ~fieldSchema=S.string),
      Table.mkField("tb", String, ~isIndex=true, ~fieldSchema=S.string),
      Table.mkField("num", Int32, ~isIndex=true, ~fieldSchema=S.int),
      Table.mkField("big", BigInt({}), ~isIndex=true, ~fieldSchema=S.string),
      Table.mkField("flag", Boolean, ~isIndex=true, ~fieldSchema=S.string),
      Table.mkField("price", BigDecimal({}), ~isIndex=true, ~fieldSchema=S.string),
      Table.mkField("at", Date, ~isIndex=true, ~fieldSchema=S.string),
      Table.mkField("meta", Json, ~isIndex=true, ~fieldSchema=S.string),
      Table.mkField("tag", Bytea, ~isIndex=true, ~fieldSchema=S.string),
      Table.mkField("tags", String, ~isArray=true, ~isIndex=true, ~fieldSchema=S.string),
      Table.mkField("ats", Date, ~isArray=true, ~isIndex=true, ~fieldSchema=S.string),
    ],
  )
  let toKey = filter => filter->parse(~table)->EntityFilter.toString(~table)

  // The key stands in for structural equality: two filters share an index if
  // and only if their keys match. Any pair colliding here would silently
  // answer one getWhere with another's rows.
  it("Gives distinct filters distinct keys", t => {
    let filters = [
      dict{"a": dict{"_eq": u("hello")}},
      dict{"a": dict{"_eq": u("hell")}},
      // A string and the number that prints the same.
      dict{"num": dict{"_eq": u("5")}},
      dict{"num": dict{"_eq": u(5)}},
      dict{"big": dict{"_eq": u("10")}},
      dict{"big": dict{"_eq": u(BigInt.fromInt(10))}},
      dict{"flag": dict{"_eq": u("true")}},
      dict{"flag": dict{"_eq": u(true)}},
      // A value that looks like the encoding's own punctuation.
      dict{"a": dict{"_eq": u(`"hello"`)}},
      dict{"a": dict{"_eq": u("5:hello")}},
      dict{"a": dict{"_eq": u("")}},
      dict{"a": dict{"_eq": u(5)}},
      dict{"a": dict{"_eq": u(BigInt.fromInt(10))}},
      dict{"a": dict{"_eq": u(true)}},
      dict{"a": dict{"_eq": u(BigDecimal.fromFloat(1.5))}},
      dict{"a": dict{"_gt": u(5)}},
      dict{"a": dict{"_lt": u(5)}},
      dict{"a": dict{"_gte": u(5)}},
      dict{"a": dict{"_lte": u(5)}},
      dict{"a": dict{"_in": u([1, 2])}},
      dict{"a": dict{"_in": u([12])}},
      dict{"a": dict{"_in": u([])}},
      // Sub-second instants, which a Date toString collapses onto one key.
      dict{"a": dict{"_eq": u(Date.fromTime(1000.))}},
      dict{"a": dict{"_eq": u(Date.fromTime(1500.))}},
      // Objects, which all stringify to "[object Object]".
      dict{"a": dict{"_eq": u({"x": 1})}},
      dict{"a": dict{"_eq": u({"x": 2})}},
      // A separator inside an element could imitate the element separator.
      dict{"a": dict{"_eq": u(["x,y"])}},
      dict{"a": dict{"_eq": u(["x", "y"])}},
      dict{"a": dict{"_eq": u(["xy"])}},
      dict{"tags": dict{"_eq": u(["x", "y"])}},
      dict{"tags": dict{"_eq": u(["xy"])}},
      dict{"tags": dict{"_eq": u(["x,y"])}},
      // The same values split differently across fields and operators.
      dict{"a": dict{"_gt": u(1)}, "b": dict{"_lt": u(2)}},
      dict{"a": dict{"_gt": u(1), "_lt": u(2)}},
      dict{"ab": dict{"_eq": u(1)}},
      dict{"a": dict{"_eq": u(1)}, "b": dict{"_eq": u(1)}},
      // A fixed-width value key followed by a field name could read as an
      // empty value list followed by a longer field name.
      dict{"a": dict{"_in": u([true])}, "b": dict{"_eq": u(1)}},
      dict{"a": dict{"_in": u([])}, "tb": dict{"_eq": u(1)}},
    ]
    let keys = filters->Array.map(toKey)
    t.expect((keys->Utils.Set.fromArray->Utils.Set.size, keys->Array.length)).toEqual((
      filters->Array.length,
      filters->Array.length,
    ))
  })

  it("Builds the key from the column's own value projection", t => {
    t.expect(
      [
        dict{"a": dict{"_eq": u("hello")}},
        dict{"num": dict{"_eq": u(5)}},
        dict{"big": dict{"_eq": u(BigInt.fromInt(10))}},
        dict{"flag": dict{"_eq": u(true)}},
        dict{"price": dict{"_eq": u(BigDecimal.fromFloat(1.5))}},
        // A Date keys by its epoch millis, not a string that stops at seconds.
        dict{"at": dict{"_eq": u(Date.fromTime(1500.))}},
        dict{"meta": dict{"_eq": u({"x": 1})}},
        dict{"tag": dict{"_eq": u(Uint8Array.fromArray([0xab]))}},
        dict{"tags": dict{"_eq": u(["x", "y"])}},
        // An array keys by its elements' own keys, so a Date[] keys by epoch
        // millis just as a Date does — no second rule for what is in an array.
        dict{"ats": dict{"_eq": u([Date.fromTime(1500.), Date.fromTime(20.)])}},
        dict{"num": dict{"_gt": u(5)}},
        dict{"num": dict{"_in": u([1, 2])}},
        dict{"num": dict{"_gt": u(1)}, "b": dict{"_lt": u("z")}},
      ]->Array.map(toKey),
    ).toEqual([
      "a_eqs5:hello;",
      "num_eqn1:5;",
      "big_eqg2:10;",
      "flag_eqt;",
      "price_eqs3:1.5;",
      "at_eqn4:1500;",
      `meta_eqs7:{"x":1};`,
      "tag_eqs2:ab;",
      "tags_eqs8:s1:xs1:y;",
      "ats_eqs12:n4:1500n2:20;",
      "num_gtn1:5;",
      "num_inn1:1n1:2;",
      "num_gtn1:1;b_lts1:z;",
    ])
  })

})
