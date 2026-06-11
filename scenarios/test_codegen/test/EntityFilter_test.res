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
