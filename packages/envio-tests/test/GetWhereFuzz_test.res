open Vitest

// A getWhere answers from Postgres for rows earlier batches committed. It has
// to return exactly the rows the filter describes for every column type,
// operator and value the filter grammar allows. Rather than enumerate the cases
// by hand, this generates rows and filters from a seeded generator and checks
// each getWhere a handler runs against the matcher applied to the same rows.
//
// Every row a query loads stays in memory and answers later filters through
// the matcher, so a row one query's SQL missed would be covered up by an
// earlier query that loaded it. Each filter is therefore pinned to a group of
// rows no other filter reads, which leaves its own SQL as the only way in.
// Rows the SQL returns past the filter never reach the handler, since they are
// matched before any index takes them, so only a missed row can show here.
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
let scenario = Scenario.make(
  ~supervised=false,
  // getWhere reads Postgres either way, and ClickHouse refuses the nullable
  // list column the grammar has to cover.
  ~unsupported=[{backend: #clickhouse, reason: "nullable list columns aren't supported there"}],
  ~schema=`
enum Kind {
  ZETA
  ALPHA
  MID
}

type Row {
  id: ID!
  group: Int!
  str: String!
  optStr: String
  quoted: String!
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
  ~configYaml=`
name: get-where-fuzz
bytes_type: uint8array
chains:
  - id: 1
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 1
    contracts:
      - name: Gravatar
        address: "0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3"
        events:
          - event: "TestEvent()"
`,
)

let entityConfig = scenario.config.userEntitiesByName->Dict.getUnsafe("Row")
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
  {
    name: "quoted",
    // Bound as parameters, never spliced in. Equality only: a database with a
    // linguistic collation orders punctuation apart from how a handler would.
    pool: ["a'b", "a\\b", "a''b", "'", "\\", "a"]->Array.map(u),
    operators: ["_eq", "_in"],
  },
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
    // only equality is compared. A document need not be an object.
    pool: [
      {"a": 1}->u,
      {"a": 2}->u,
      {"a": 1, "b": [1, 2]}->u,
      {"b": "x"}->u,
      "abc"->u,
      true->u,
      [1, 2]->u,
    ],
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

let rowsPerGroup = 12

let makeRow = (random, ~index) => {
  let row = Dict.make()
  row->Dict.set("id", `r${index->Int.toString}`->u)
  row->Dict.set("group", (index / rowsPerGroup)->u)
  columns->Array.forEach(column => row->Dict.set(column.name, random->pick(column.pool)))
  row
}

let makeFilter = (random, ~group) => {
  let filter = Dict.make()
  filter->Dict.set("group", dict{"_eq": group->u})
  let fieldsCount = random() < 0.3 ? 3 : 2
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

type rowOps = {
  set: dict<unknown> => unit,
  getWhere: dict<dict<unknown>> => promise<array<unknown>>,
}
type handlerContext = {@as("Row") row: rowOps}

let inHandler = (~block, run: handlerContext => promise<unit>): MockSource.itemMock => {
  blockNumber: block,
  logIndex: 0,
  handler: async args =>
    await args.context->(Utils.magic: Internal.handlerContext => handlerContext)->run,
}

type mismatch = {seed: int, filter: string, expected: array<string>, actual: array<string>}

describe("A getWhere over committed rows", () => {
  scenario->Scenario.it(
    "returns exactly the rows every generated filter describes",
    ~sources=[{chain: 1}],
    ~timeout=60_000,
    async (~t, ~indexer, ~source) => {
      let source = source(1)
      await Utils.delay(0)
      await Scenario.resolveInitialHeight(~t, ~source, ~head=100)
      let running = ref(indexer)
      let mismatches = []
      let matched = ref(0)

      for seed in 1 to 3 {
        let random = makeRandom(seed)
        let filters = Array.fromInitializer(~length=300, group => makeFilter(random, ~group))
        let rows = Array.fromInitializer(
          ~length=filters->Array.length * rowsPerGroup,
          index => makeRow(random, ~index),
        )
        let writeBlock = seed * 2 - 1

        // Ids repeat across seeds, so each seed's rows replace the previous ones.
        source.resolveGetItemsOrThrow(
          [
            inHandler(
              ~block=writeBlock,
              async context => rows->Array.forEach(row => context.row.set(row)),
            ),
          ],
          ~filter=MockSource.coveringBlock(writeBlock),
          ~latestFetchedBlockNumber=writeBlock,
        )
        await running.contents.getBatchWritePromise()

        // Restarted, so nothing the writes left in memory can answer a getWhere.
        source.setAutoHeight(100)
        running := (await running.contents.restart())
        let results = []
        source.resolveGetItemsOrThrow(
          [
            inHandler(
              ~block=writeBlock + 1,
              async context =>
                for idx in 0 to filters->Array.length - 1 {
                  results
                  ->Array.push((await context.row.getWhere(filters->Array.getUnsafe(idx)))->ids)
                  ->ignore
                },
            ),
          ],
          ~filter=MockSource.coveringBlock(writeBlock + 1),
          ~latestFetchedBlockNumber=writeBlock + 1,
        )
        await running.contents.getBatchWritePromise()

        let entities = rows->(Utils.magic: array<dict<unknown>> => array<Internal.entity>)
        filters->Array.forEachWithIndex(
          (raw, idx) => {
            let filter = raw->EntityFilter.parseOrThrow(~entityName=entityConfig.name, ~table)
            let expected =
              entities
              ->Array.filter(filter->EntityFilter.makeMatcher(~table))
              ->(Utils.magic: array<Internal.entity> => array<unknown>)
              ->ids
            let actual = results->Array.get(idx)->Option.getOr(["missing"])
            if expected->Array.length > 0 {
              matched := matched.contents + 1
            }
            if expected != actual {
              mismatches
              ->Array.push({seed, filter: filter->EntityFilter.toString(~table), expected, actual})
              ->ignore
            }
          },
        )
      }

      t.expect((mismatches, matched.contents > 200)).toEqual(([], true))
    },
  )
})
