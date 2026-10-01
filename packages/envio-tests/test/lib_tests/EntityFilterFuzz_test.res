open Vitest

// The in-memory matcher answers a getWhere for rows the handler already wrote,
// and Postgres answers it for the rest. The two have to agree on every column
// type, operator and value the filter grammar allows, or one call returns
// different rows depending on whether its rows were cached. Rather than
// enumerate the cases by hand, this generates rows and filters from a seeded
// generator and compares the matcher against a real query, so every
// combination the grammar can express is reachable.
let makeRandom: int => unit => float = %raw(`seed => {
  let a = seed >>> 0
  return () => {
    a = (a + 0x6d2b79f5) | 0
    let t = Math.imul(a ^ (a >>> 15), 1 | a)
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296
  }
}`)

external u: 'a => unknown = "%identity"

// Enum members are declared out of alphabetical order on purpose: Postgres
// orders an enum by declaration, and the matcher has to follow.
let config = TestConfig.fromUserApi(
  ~schema=`
enum Kind {
  ZETA
  ALPHA
  MID
}

type Row {
  id: ID!
  str: String!
  optStr: String
  int_: Int!
  optInt: Int
  float_: Float!
  bool: Boolean!
  big: BigInt!
  dec: BigDecimal!
  ts: Timestamp!
  optTs: Timestamp
  bytes: Bytes!
  json: Json!
  kind: Kind!
  strs: [String!]!
  ints: [Int!]!
  bigs: [BigInt!]!
  optBytes: [Bytes!]
}
`,
  `
name: entity-filter-fuzz
bytes_type: uint8array
chains:
  - id: 1
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 1
`,
)
let entityConfig = config.userEntitiesByName->Dict.getUnsafe("Row")
let table = entityConfig.table

type column = {
  name: string,
  // Values a row can hold. Small on purpose, so equalities and shared array
  // prefixes come up often enough to matter.
  pool: array<unknown>,
  // Filters draw from the same pool, minus a nullable column's undefined.
  operators: array<string>,
}

let allOperators = ["_eq", "_gt", "_lt", "_gte", "_lte", "_in"]

let dates = [0., 1000., 1500., 1501., 2000., 31536000000.]->Array.map(Date.fromTime)
let strings = ["a", "ab", "b", "ba", "z", "aa", "1a", "a1", ""]
let ints = [0, 1, 2, 3, 4, 5, -1]
let bigs =
  [0, 1, 2, 3, 4, 5, -1]
  ->Array.map(BigInt.fromInt)
  ->Array.concat([BigInt.fromStringOrThrow("100000000000000000000")])
let undefined = %raw(`undefined`)
let nullable = pool => pool->Array.concat([undefined])

let columns = [
  {name: "str", pool: strings->Array.map(u), operators: allOperators},
  {name: "optStr", pool: strings->Array.map(u)->nullable, operators: allOperators},
  {name: "int_", pool: ints->Array.map(u), operators: allOperators},
  {name: "optInt", pool: ints->Array.map(u)->nullable, operators: allOperators},
  {name: "float_", pool: [0.5, 1.5, -2.25, 3., 1e10]->Array.map(u), operators: allOperators},
  {name: "bool", pool: [true, false]->Array.map(u), operators: allOperators},
  {name: "big", pool: bigs->Array.map(u), operators: allOperators},
  {
    name: "dec",
    // 1.50 equals 1.5 as a number, and both sides have to say so.
    pool: ["0", "1.5", "2.25", "10", "-3.5", "1.50"]
    ->Array.map(BigDecimal.fromStringUnsafe)
    ->Array.map(u),
    operators: allOperators,
  },
  {name: "ts", pool: dates->Array.map(u), operators: allOperators},
  {name: "optTs", pool: dates->Array.map(u)->nullable, operators: allOperators},
  {
    name: "bytes",
    pool: [[], [0], [0, 0], [1], [1, 2], [255], [1, 2, 3]]
    ->Array.map(Uint8Array.fromArray)
    ->Array.map(u),
    operators: allOperators,
  },
  {
    name: "json",
    // jsonb has an ordering, but not one a handler could sensibly rely on, so
    // only equality is compared.
    pool: [{"a": 1}->u, {"a": 2}->u, {"a": 1, "b": [1, 2]}->u, {"b": "x"}->u],
    operators: ["_eq", "_in"],
  },
  {name: "kind", pool: ["ZETA", "ALPHA", "MID"]->Array.map(u), operators: allOperators},
  {
    name: "strs",
    pool: [[], ["a"], ["a", "b"], ["b"], ["a", "a"], ["ab"]]->Array.map(u),
    operators: allOperators,
  },
  {
    name: "ints",
    pool: [[], [1], [1, 2], [2], [1, 2, 3], [-1]]->Array.map(u),
    operators: allOperators,
  },
  {
    name: "bigs",
    pool: [[], [1], [1, 2], [2]]->Array.map(a => a->Array.map(BigInt.fromInt))->Array.map(u),
    operators: allOperators,
  },
  {
    name: "optBytes",
    pool: [[], [[1]], [[1], [1, 2]], [[1, 2]], [[2]]]
    ->Array.map(a => a->Array.map(Uint8Array.fromArray))
    ->Array.map(u)
    ->nullable,
    operators: allOperators,
  },
]

let pick = (random, items) =>
  items->Array.getUnsafe((random() *. items->Array.length->Int.toFloat)->Float.toInt)

let makeRow = (random, ~index) => {
  let row = Dict.make()
  row->Dict.set("id", `r${index->Int.toString}`->u)
  columns->Array.forEach(column => row->Dict.set(column.name, random->pick(column.pool)))
  row
}

let makeFilter = random => {
  let filter = Dict.make()
  let fieldsCount = random() < 0.3 ? 2 : 1
  while filter->Dict.keysToArray->Array.length < fieldsCount {
    let column = random->pick(columns)
    let values = column.pool->Array.filter(value => !(value->EntityFilter.nullish))
    let operators = Dict.make()
    let operatorsCount = random() < 0.25 ? 2 : 1
    while operators->Dict.keysToArray->Array.length < operatorsCount {
      let operator = random->pick(column.operators)
      let value = if operator === "_in" {
        Array.fromInitializer(~length=(random() *. 4.)->Float.toInt, _ => random->pick(values))->u
      } else {
        random->pick(values)
      }
      operators->Dict.set(operator, value)
    }
    filter->Dict.set(column.name, operators)
  }
  filter
}

let ids = (rows: array<unknown>) =>
  rows
  ->Array.map(row => (row->(Utils.magic: unknown => {"id": string}))["id"])
  ->Array.toSorted(String.compare)

describe("EntityFilter matcher against Postgres", () => {
  Async.it("Agrees with the query for every generated filter", async t => {
    let pgSchema = "entity_filter_fuzz"
    let sql = PgStorage.makeClient()
    let storage = PgStorage.make(
      ~sql,
      ~pgHost=Env.Db.host,
      ~pgSchema,
      ~pgPort=Env.Db.port,
      ~pgUser=Env.Db.user,
      ~pgDatabase=Env.Db.database,
      ~pgPassword=Env.Db.password,
      ~isHasuraEnabled=false,
      ~ecosystem=Evm,
    )
    let _ = await storage.initialize(
      ~contractMapping=config.contractMapping,
      ~entities=config.userEntities,
      ~enums=config.allEnums->Array.concat([
        EntityHistory.RowAction.config->Table.fromGenericEnumConfig,
      ]),
      ~envioInfo=JSON.Object(Dict.make()),
    )

    let mismatches = []
    let matched = ref(0)

    for seed in 1 to 3 {
      let random = makeRandom(seed)
      let rows = Array.fromInitializer(~length=60, index => makeRow(random, ~index))

      // Ids repeat across seeds, so each seed's rows replace the previous ones.
      try {
        await PgStorage.setOrThrow(
          sql,
          ~items=rows->(Utils.magic: array<dict<unknown>> => array<unknown>),
          ~table,
          ~itemSchema=entityConfig.schema->S.toUnknown,
          ~pgSchema,
          ~setQueryCache=PgStorage.makeSetQueryCache(),
        )
      } catch {
      | Persistence.StorageError({message, reason}) =>
        JsError.throwWithMessage(
          message ++ " " ++ reason->Utils.prettifyExn->(Utils.magic: exn => JSON.t)->JSON.stringify,
        )
      }

      let entities = rows->(Utils.magic: array<dict<unknown>> => array<Internal.entity>)

      for _ in 1 to 300 {
        let filter =
          makeFilter(random)->EntityFilter.parseOrThrow(~entityName=entityConfig.name, ~table)
        let matcher = filter->EntityFilter.makeMatcher(~table)
        let expected =
          entities
          ->Array.filter(matcher)
          ->(Utils.magic: array<Internal.entity> => array<unknown>)
          ->ids
        let actual = switch await storage.loadOrThrow(~filter, ~table) {
        | rows => rows->ids
        | exception Persistence.StorageError({message, reason}) => [
            message ++
            " " ++
            reason->Utils.prettifyExn->(Utils.magic: exn => JSON.t)->JSON.stringify,
          ]
        }
        if expected->Array.length > 0 {
          matched := matched.contents + 1
        }
        if expected != actual {
          mismatches->Array.push({
            "seed": seed,
            "filter": filter->EntityFilter.toString(~table),
            "inMemory": expected,
            "postgres": actual,
          })
        }
      }
    }

    let _ = await sql->Postgres.unsafe(`DROP SCHEMA IF EXISTS "${pgSchema}" CASCADE;`)
    await storage.close()

    t.expect({"mismatches": mismatches, "someFiltersMatched": matched.contents > 200}).toEqual({
      "mismatches": [],
      "someFiltersMatched": true,
    })
  })
})
