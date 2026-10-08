open Vitest

// Random entities, random rows, set by a handler and read back after the batch
// commits. What this covers that a case written by hand does not is the
// combinations: which of the two inserts a table's columns select, where a
// value lands in the arena, and what the growth of a column's payload does to
// the rows after it. A failure names the seed and the schema that produced it.

@val @scope(("process", "env")) external seedEnv: option<string> = "ENVIO_FUZZ_SEED"
@val @scope(("process", "env")) external casesEnv: option<string> = "ENVIO_FUZZ_CASES"

// xorshift32: a generator whose whole state is the seed, so quoting the seed is
// quoting the case.
type random = {mutable state: int}

let make = seed => {state: seed === 0 ? 1 : seed}

let next = random => {
  let x = random.state
  let x = x->Int.bitwiseXor(x->Int.shiftLeft(13))
  let x = x->Int.bitwiseXor(x->Int.shiftRightUnsigned(17))
  let x = x->Int.bitwiseXor(x->Int.shiftLeft(5))
  random.state = x->Int.bitwiseAnd(0x7fffffff)
  random.state
}

let below = (random, bound) => random->next->mod(bound)
let pick = (random, options: array<'a>) =>
  options->Array.getUnsafe(random->below(options->Array.length))
let chance = (random, percent) => random->below(100) < percent

external unknown: 'a => unknown = "%identity"

let bytes = (values): Uint8Array.t => values->Uint8Array.fromArray

// A column's GraphQL type, and the values worth trying: the ones at the edges
// of what each type can hold, and the ones whose text means something to the
// layer that renders it.
type generator = {
  name: string,
  graphql: string,
  // A field directive the type needs, after the type.
  config: string,
  canBeList: bool,
  values: array<unknown>,
}

let generators = [
  {
    name: "text",
    graphql: "String",
    config: "",
    canBeList: true,
    values: [
      ""->unknown,
      "plain"->unknown,
      `a,b{"x"}\\`->unknown,
      "NULL"->unknown,
      "{}"->unknown,
      "h\u{e9}llo \u{1F600}"->unknown,
      "line\nbreak\ttab"->unknown,
      "'quoted'"->unknown,
      "long"->String.repeat(200)->unknown,
    ],
  },
  {
    name: "flag",
    graphql: "Boolean",
    config: "",
    // A schema can't declare a list of booleans.
    canBeList: false,
    values: [true->unknown, false->unknown],
  },
  {
    name: "int",
    graphql: "Int",
    config: "",
    canBeList: true,
    values: [0->unknown, 1->unknown, -1->unknown, 2147483647->unknown, -2147483648->unknown],
  },
  {
    name: "float",
    graphql: "Float",
    config: "",
    canBeList: true,
    values: [
      0.->unknown,
      1.5->unknown,
      -1.5->unknown,
      1.7976931348623157e308->unknown,
      5e-324->unknown,
    ],
  },
  {
    name: "big",
    graphql: "BigInt",
    config: "",
    canBeList: true,
    values: [
      0n->unknown,
      1n->unknown,
      -1n->unknown,
      9223372036854775807n->unknown,
      -9223372036854775808n->unknown,
      123456789012345678901234567890n->unknown,
      -123456789012345678901234567890n->unknown,
    ],
  },
  {
    name: "dec",
    graphql: "BigDecimal",
    config: "",
    canBeList: true,
    values: ["0", "1.5", "-2.25", "1e20", "0.000001"]->Array.map(text =>
      BigDecimal.fromStringUnsafe(text)->unknown
    ),
  },
  {
    name: "at",
    graphql: "Timestamp",
    config: "",
    // A schema can't declare a list of timestamps.
    canBeList: false,
    values: [0., 1234567890123., -86400000., 253402300799000., 1700000000001.]->Array.map(ms =>
      Date.fromTime(ms)->unknown
    ),
  },
  {
    name: "blob",
    graphql: "Bytes",
    config: "",
    canBeList: true,
    values: [
      bytes([])->unknown,
      bytes([0])->unknown,
      bytes([0xde, 0xad, 0x00, 0xbe])->unknown,
      bytes(Array.make(~length=600, 0x41))->unknown,
    ],
  },
  {
    name: "sizedBig",
    graphql: "BigInt",
    config: " @config(precision: 20)",
    canBeList: false,
    values: [0n->unknown, 1n->unknown, -1n->unknown, 99999999999999999999n->unknown],
  },
  {
    name: "scaledDec",
    graphql: "BigDecimal",
    config: " @config(precision: 12, scale: 4)",
    canBeList: false,
    values: ["0", "1.5", "-2.25", "12345678.9999"]->Array.map(text =>
      BigDecimal.fromStringUnsafe(text)->unknown
    ),
  },
  {
    name: "doc",
    graphql: "Json",
    config: "",
    // No list of documents: each element would have to be rendered as its own
    // text, which only a scalar json column does today.
    canBeList: false,
    // No bare `null` document: stored, it is indistinguishable from the
    // absence of a value, which is a question about the column, not this.
    values: [
      JSON.Encode.int(1)->unknown,
      JSON.Encode.string(`a "quoted", {braced} value`)->unknown,
      JSON.Encode.array([JSON.Encode.int(1), JSON.Encode.bool(true)])->unknown,
      JSON.Encode.object(Dict.fromArray([("k", JSON.Encode.string("v"))]))->unknown,
    ],
  },
  {
    name: "status",
    graphql: "Status",
    config: "",
    canBeList: true,
    values: ["pending", "settled", "void"]->Array.map(unknown),
  },
  {
    name: "side",
    graphql: "Side",
    config: "",
    canBeList: true,
    values: ["buy", "sell"]->Array.map(unknown),
  },
]

type column = {
  generator: generator,
  // What the entity record is keyed by: a relation spells it with `_id`.
  name: string,
  isList: bool,
  isOptional: bool,
  isRelation: bool,
}

let makeColumn = (random, index) => {
  let generator = random->pick(generators)
  let isList = generator.canBeList && random->chance(25)
  let isOptional = random->chance(35)
  let isRelation = generator.name === "text" && !isList && random->chance(15)
  let field = `${generator.name}Col${index->Int.toString}`
  {generator, name: isRelation ? field ++ "_id" : field, isList, isOptional, isRelation}
}

let fieldOf = column => {
  let field = column.isRelation ? column.name->String.slice(~start=0, ~end=-3) : column.name
  let scalar = column.isRelation ? "Other" : column.generator.graphql
  let typ = column.isList ? `[${scalar}!]` : scalar
  `  ${field}: ${typ}${column.isOptional ? "" : "!"}${column.generator.config}`
}

let makeValue = (random, column) =>
  if column.isOptional && random->chance(30) {
    %raw(`undefined`)
  } else if column.isList {
    Array.fromInitializer(~length=random->below(4), _ =>
      random->pick(column.generator.values)
    )->unknown
  } else {
    random->pick(column.generator.values)
  }

// What the statement that binds a cell at a time splits a batch at.
let maxItemsPerChunk = 500

type case = {
  seed: int,
  columns: array<column>,
  derived: bool,
  snakeCase: bool,
  rows: array<dict<unknown>>,
}

let makeCase = seed => {
  let random = make(seed)
  let columns = Array.fromInitializer(~length=1 + random->below(6), index =>
    random->makeColumn(index)
  )
  // Mostly small batches, and now and then one past the point where the
  // statement that binds a cell at a time splits into chunks.
  let rowCount = random->chance(8) ? maxItemsPerChunk + random->below(60) : 1 + random->below(11)
  let derived = random->chance(20)
  let snakeCase = random->chance(15)
  let rows = Array.fromInitializer(~length=rowCount, index => {
    let row = Dict.make()
    row->Dict.set("id", `row-${index->Int.toString}`->unknown)
    columns->Array.forEach(column => row->Dict.set(column.name, random->makeValue(column)))
    row
  })
  {seed, columns, derived, snakeCase, rows}
}

let schemaOf = case =>
  `
enum Status {
  pending
  settled
  void
}

enum Side {
  buy
  sell
}

type Rand {
  id: ID!
${case.columns->Array.map(fieldOf)->Array.join("\n")}${case.derived
      ? `\n  children: [Other!]! @derivedFrom(field: "parent")`
      : ""}
}

type Other {
  id: ID!
  parent: Rand
}
`

let configYamlOf = case =>
  `
name: random-entities
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
          - event: "TestEvent()"${case.snakeCase
      ? "\nstorage:\n  postgres:\n    column_name_format: snake_case"
      : ""}
`

// What a row holds, as text that keeps the type apart from the value — so a
// `1.5` that came back as a string rather than a number is a difference.
let shown = (case, rows: array<dict<unknown>>) =>
  rows
  ->Array.toSorted((a, b) =>
    String.compare(
      a->Dict.getUnsafe("id")->(Utils.magic: unknown => string),
      b->Dict.getUnsafe("id")->(Utils.magic: unknown => string),
    )
  )
  ->Array.map(row =>
    [("id", PgValue.shown(row->Dict.getUnsafe("id")))]->Array.concat(
      case.columns->Array.map(column => (
        column.name,
        PgValue.shown(row->Dict.getUnsafe(column.name)),
      )),
    )
  )
  ->(Utils.magic: 'a => JSON.t)
  ->JSON.stringify

type randOps = {set: dict<unknown> => unit}
type handlerContext = {@as("Rand") rand: randOps}

let cases = casesEnv->Option.flatMap(text => Int.fromString(text))->Option.getOr(40)
let rootSeed = seedEnv->Option.flatMap(text => Int.fromString(text))->Option.getOr(20260917)

describe("Entities a handler sets", () => {
  let name = "come back as they went in, for any entity the generator builds"
  switch IndexerRunner.selectedBackend {
  | #clickhouse =>
    Async.it_skip(`${name} [no clickhouse: it refuses the nullable lists generated]`, async _ => ())
  | #postgres =>
    Async.it(
      name,
      async t => {
        // A generator can quietly stop producing a shape and the run would still
        // pass, proving less than it looks like it proves.
        let seen = Dict.make()
        let saw = what => seen->Dict.set(what, true)
        let failures = []

        for index in 0 to cases - 1 {
          let case = makeCase(rootSeed + index)
          if case.derived {
            saw("a derived field")
          }
          if case.snakeCase {
            saw("a renamed column")
          }
          if case.rows->Array.length > maxItemsPerChunk {
            saw("a batch past one chunk")
          }
          saw(case.columns->Array.some(column => column.isList) ? "a list table" : "a scalar table")
          case.columns->Array.forEach(column => {
            saw(column.generator.name)
            if column.isList {
              saw("a list column")
            }
            if column.isOptional {
              saw("an optional column")
            }
            if column.isRelation {
              saw("a relation column")
            }
          })

          let scenario = Scenario.make(
            ~supervised=false,
            ~schema=schemaOf(case),
            ~configYaml=configYamlOf(case),
          )
          await scenario->Scenario.run(~sources=[{chain: 1}], async (~indexer, ~source) => {
            let source = source(1)
            source.resolveGetHeightOrThrow(100)
            source.resolveGetItemsOrThrow(
              [
                {
                  blockNumber: 1,
                  logIndex: 0,
                  handler: async args => {
                    let context =
                      args.context->(Utils.magic: Internal.handlerContext => handlerContext)
                    case.rows->Array.forEach(row => context.rand.set(row))
                  },
                },
              ],
              ~latestFetchedBlockNumber=1,
            )
            await indexer.getBatchWritePromise()
            let readBack: array<dict<unknown>> = await indexer.query("Rand")
            let (wrote, read) = (shown(case, case.rows), shown(case, readBack))
            if wrote !== read {
              failures
              ->Array.push(
                `seed ${case.seed->Int.toString}:${schemaOf(case)}\nwrote ${wrote}\nread  ${read}`,
              )
              ->ignore
            }
          })
        }

        let missing =
          generators
          ->Array.map(generator => generator.name)
          ->Array.concat([
            "a list column",
            "an optional column",
            "a relation column",
            "a renamed column",
            "a derived field",
            "a batch past one chunk",
            "a list table",
            "a scalar table",
          ])
          ->Array.filter(what => seen->Dict.get(what)->Option.isNone)

        t.expect((failures->Array.slice(~start=0, ~end=1), missing)).toEqual(([], []))
      },
      ~timeout=300_000,
    )
  }
})
