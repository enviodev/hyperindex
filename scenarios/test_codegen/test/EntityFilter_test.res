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
