open Vitest

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
      Table.mkField("owner", String, ~linkedEntity="Owner", ~fieldSchema=S.string),
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
    ).toThrowErrorEqual(
      "Unexpected filter And(a:Eq:2) in a merged batch. Filters batched into a single query must use the same operator and field.",
    )
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
