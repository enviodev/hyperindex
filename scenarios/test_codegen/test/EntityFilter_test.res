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

describe("EntityFilter.toSqlCondition", () => {
  let table = Table.mkTable(
    "users",
    ~fields=[
      Table.mkField("id", String, ~isPrimaryKey=true, ~fieldSchema=S.string),
      Table.mkField("score", Int32, ~fieldSchema=S.int),
    ],
  )

  it("Should create condition and params for loading multiple records by IDs", t => {
    let params = []
    let condition =
      EntityFilter.In({
        fieldName: "id",
        fieldValue: ["1", "2"]->(Utils.magic: array<string> => array<unknown>),
      })->EntityFilter.toSqlCondition(~table, ~params)

    t.expect((condition, params)).toEqual((
      `"id" = ANY($1)`,
      [["1", "2"]->(Utils.magic: array<string> => JSON.t)],
    ))
  })

  it("Should create condition and params for a scalar comparison", t => {
    let params = []
    let condition =
      EntityFilter.Gt({
        fieldName: "score",
        fieldValue: 5->(Utils.magic: int => unknown),
      })->EntityFilter.toSqlCondition(~table, ~params)

    t.expect((condition, params)).toEqual((`"score" > $1`, [5->(Utils.magic: int => JSON.t)]))
  })

  it("Should number params across nested and filters", t => {
    let params = []
    let condition =
      EntityFilter.And({
        filters: [
          Eq({fieldName: "id", fieldValue: "1"->(Utils.magic: string => unknown)}),
          And({
            filters: [
              Gt({fieldName: "score", fieldValue: 5->(Utils.magic: int => unknown)}),
              Lt({fieldName: "score", fieldValue: 10->(Utils.magic: int => unknown)}),
            ],
          }),
        ],
      })->EntityFilter.toSqlCondition(~table, ~params)

    t.expect((condition, params)).toEqual((
      `("id" = $1 AND ("score" > $2 AND "score" < $3))`,
      [
        "1"->(Utils.magic: string => JSON.t),
        5->(Utils.magic: int => JSON.t),
        10->(Utils.magic: int => JSON.t),
      ],
    ))
  })

  it("Should throw a StorageError for an empty and filter", t => {
    let result = try {
      let _ = EntityFilter.And({filters: []})->EntityFilter.toSqlCondition(~table, ~params=[])
      None
    } catch {
    | Persistence.StorageError({message}) => Some(message)
    }

    t.expect(result).toEqual(
      Some(
        `Failed loading "users" from storage. The "and" filter must contain at least one nested filter.`,
      ),
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
