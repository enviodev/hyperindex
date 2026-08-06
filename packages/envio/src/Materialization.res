// Runs the write plans the CLI compiles from `tables:` in config.yaml.
//
// Each plan is one event's contribution to one table, and it goes through the
// same handler surface user code uses — `context.<Table>.get`/`set` — so
// materialized writes land in the managed entity-change pipeline: preload
// batching, entity validation, checkpoint history, reorg rollback and atomic
// commits all apply without a second write path.
//
// A reducer (`_sum`) is therefore a read-modify-write, not a blind `+=`. The
// history table snapshots the whole row per checkpoint, so a rollback restores
// the previous balance — and removes the row entirely if the contribution that
// created it is rolled back.

@get_index external field: (unknown, string) => unknown = ""

type numeric =
  | @as("int") Int | @as("float") Float | @as("bigint") BigInt | @as("bigdecimal") BigDecimal

let numericSchema = S.enum([Int, Float, BigInt, BigDecimal])

// A compiled expression: the plan JSON is walked once at startup and turned into
// a closure, so per-event work is just the closure call.
type eval = unknown => unknown

let throwInvalid = (message): 'a =>
  JsError.throwWithMessage(`Invalid indexer config: ${message} Run \`envio codegen\` again.`)

let decodeField = (json: JSON.t, name) =>
  switch json->JSON.Decode.object {
  | Some(fields) => fields->Dict.get(name)
  | None => None
  }

let requireField = (json: JSON.t, name) =>
  switch json->decodeField(name) {
  | Some(value) => value
  | None => throwInvalid(`a materialization expression is missing \`${name}\`.`)
  }

let requireString = (json: JSON.t, name) =>
  switch json->requireField(name) {
  | String(value) => value
  | _ => throwInvalid(`a materialization expression has a non-string \`${name}\`.`)
  }

let requireArray = (json: JSON.t, name) =>
  switch json->requireField(name) {
  | Array(items) => items
  | _ => throwInvalid(`a materialization expression has a non-array \`${name}\`.`)
  }

let parseNumeric = (json: JSON.t, name) =>
  try json->requireField(name)->S.parseJsonOrThrow(numericSchema) catch {
  | S.Raised(_) => throwInvalid(`\`${name}\` is not a known numeric type.`)
  }

let bigIntOfString = value =>
  switch BigInt.fromString(value) {
  | Some(value) => value
  | None => throwInvalid(`\`${value}\` is not a valid BigInt literal.`)
  }

let bigDecimalOfString = value =>
  switch BigDecimal.fromString(value) {
  | Some(value) => value
  | None => throwInvalid(`\`${value}\` is not a valid BigDecimal literal.`)
  }

let add = (numeric: numeric, a: unknown, b: unknown): unknown =>
  switch numeric {
  | BigDecimal =>
    a
    ->(Utils.magic: unknown => BigDecimal.t)
    ->BigDecimal.plus(b->(Utils.magic: unknown => BigDecimal.t))
    ->(Utils.magic: BigDecimal.t => unknown)
  // `+` is exact for both JS numbers and bigints, and the compiler already
  // rejected mixing the two in one column.
  | Int | Float | BigInt => %raw(`a + b`)
  }

let zero = (numeric: numeric): unknown =>
  switch numeric {
  | Int | Float => 0->(Utils.magic: int => unknown)
  | BigInt => 0n->(Utils.magic: bigint => unknown)
  | BigDecimal => BigDecimal.zero->(Utils.magic: BigDecimal.t => unknown)
  }

let negate = (numeric: numeric, value: unknown): unknown =>
  switch numeric {
  | BigDecimal =>
    BigDecimal.zero
    ->BigDecimal.minus(value->(Utils.magic: unknown => BigDecimal.t))
    ->(Utils.magic: BigDecimal.t => unknown)
  | Int | Float | BigInt => %raw(`-value`)
  }

// BigInt renders in decimal, addresses in their configured casing (the decoder
// already produced them that way), and numbers/booleans canonically — which is
// what `String` does for all of them.
let toText: unknown => string = %raw(`String`)

let rec compileExpr = (json: JSON.t): eval => {
  switch json->requireString("kind") {
  | "path" =>
    let path =
      json
      ->requireArray("path")
      ->Array.map(segment =>
        switch segment {
        | String(segment) => segment
        | _ => throwInvalid("a materialization path segment is not a string.")
        }
      )
    switch path {
    | [only] => event => event->field(only)
    | path => event => path->Array.reduce(event, field)
    }
  | "string" =>
    let value = json->requireString("value")->(Utils.magic: string => unknown)
    _ => value
  | "bool" =>
    let value = json->requireField("value")->(Utils.magic: JSON.t => unknown)
    _ => value
  | "int" | "float" =>
    let value = json->requireField("value")->(Utils.magic: JSON.t => unknown)
    _ => value
  | "bigint" =>
    let value = json->requireString("value")->bigIntOfString->(Utils.magic: bigint => unknown)
    _ => value
  | "bigdecimal" =>
    let value =
      json->requireString("value")->bigDecimalOfString->(Utils.magic: BigDecimal.t => unknown)
    _ => value
  | "null" => _ => %raw(`null`)
  | "negate" =>
    let numeric = json->parseNumeric("type")
    let inner = json->requireField("expr")->compileExpr
    event => numeric->negate(inner(event))
  | "concat" =>
    let separator = switch json->decodeField("separator") {
    | Some(String(separator)) => separator
    | _ => ""
    }
    let parts = json->requireArray("values")->Array.map(compileExpr)
    event =>
      parts
      ->Array.map(part => part(event)->toText)
      ->Array.joinUnsafe(separator)
      ->(Utils.magic: string => unknown)
  | kind => throwInvalid(`\`${kind}\` is not a known materialization expression.`)
  }
}

type predicate = unknown => bool

let compareUnsafe: (string, unknown, unknown) => bool = %raw(`function (op, a, b) {
  switch (op) {
    case "eq": return a == b;
    case "ne": return a != b;
    case "gt": return a > b;
    case "gte": return a >= b;
    case "lt": return a < b;
    case "lte": return a <= b;
  }
}`)

let rec compileFilter = (json: JSON.t): predicate => {
  switch json->requireString("kind") {
  | "and" =>
    let parts = json->requireArray("filters")->Array.map(compileFilter)
    event => parts->Array.every(part => part(event))
  | "or" =>
    let parts = json->requireArray("filters")->Array.map(compileFilter)
    event => parts->Array.some(part => part(event))
  | "cmp" =>
    let op = json->requireString("op")
    switch op {
    | "eq" | "ne" | "gt" | "gte" | "lt" | "lte" => ()
    | op => throwInvalid(`\`${op}\` is not a known filter operator.`)
    }
    let left =
      JSON.Object(
        Dict.fromArray([("kind", JSON.String("path")), ("path", json->requireField("path"))]),
      )->compileExpr
    let right = json->requireField("value")->compileExpr
    event => compareUnsafe(op, left(event), right(event))
  | "in" =>
    let negated = json->decodeField("negated") == Some(JSON.Boolean(true))
    let left =
      JSON.Object(
        Dict.fromArray([("kind", JSON.String("path")), ("path", json->requireField("path"))]),
      )->compileExpr
    let values = json->requireArray("values")->Array.map(compileExpr)
    event => {
      let value = left(event)
      let found = values->Array.some(candidate => compareUnsafe("eq", value, candidate(event)))
      found !== negated
    }
  | kind => throwInvalid(`\`${kind}\` is not a known materialization filter.`)
  }
}

type write = {
  table: string,
  filter: option<predicate>,
  id: eval,
  setFields: array<(string, eval)>,
  // Non-empty for an aggregate table, which has to read the row before writing.
  sumFields: array<(string, numeric, eval)>,
}

type plan = {
  contractName: string,
  eventName: string,
  write: write,
}

let compilePlan = (json: JSON.t): plan => {
  let table = json->requireString("table")
  let setFields = []
  let sumFields = []
  json
  ->requireArray("fields")
  ->Array.forEach(field => {
    let name = field->requireString("name")
    let expr = field->requireField("expr")->compileExpr
    switch field->requireString("op") {
    | "set" => setFields->Array.push((name, expr))
    | "sum" => sumFields->Array.push((name, field->parseNumeric("type"), expr))
    | op => throwInvalid(`\`${op}\` is not a known materialization field operation.`)
    }
  })
  {
    contractName: json->requireString("contractName"),
    eventName: json->requireString("eventName"),
    write: {
      table,
      filter: json->decodeField("filter")->Option.map(compileFilter),
      id: json->requireField("id")->compileExpr,
      setFields,
      sumFields,
    },
  }
}

// Materialized tables are read-only through the ordinary `context.<Table>`
// accessor, so the writes go through the reserved one instead.
let getEntityOperations = (context: Internal.handlerContext, table): Internal.entityHandlerContext<
  Internal.entity,
> =>
  context
  ->(Utils.magic: Internal.handlerContext => unknown)
  ->field(Internal.materializerProp)
  ->(Utils.magic: unknown => string => Internal.entityHandlerContext<Internal.entity>)
  ->(get => get(table))

let runWrite = async (write: write, ~event: unknown, ~context: Internal.handlerContext) => {
  let matches = switch write.filter {
  | Some(filter) => filter(event)
  | None => true
  }
  if matches {
    let operations = context->getEntityOperations(write.table)
    let id = write.id(event)
    let row = Dict.make()
    row->Dict.set("id", id)
    write.setFields->Array.forEach(((name, expr)) => row->Dict.set(name, expr(event)))
    if write.sumFields->Utils.Array.notEmpty {
      // Read-your-write: an event that contributes twice to the same id (a
      // self-transfer) sees its own first contribution here, so the two cancel
      // instead of racing to overwrite each other.
      let existing =
        (await operations.get(id->(Utils.magic: unknown => EntityId.t)))->(
          Utils.magic: option<Internal.entity> => option<unknown>
        )
      write.sumFields->Array.forEach(((name, numeric, expr)) => {
        let previous = switch existing {
        | Some(existing) => existing->field(name)
        | None => numeric->zero
        }
        row->Dict.set(name, numeric->add(previous, expr(event)))
      })
    }
    operations.set(row->(Utils.magic: dict<unknown> => Internal.entity))
  }
}

type eventPlans = {
  contractName: string,
  eventName: string,
  writes: array<write>,
}

// One handler per (contract, event), running every plan that event feeds in
// config order. Sequential on the execute pass on purpose: two plans writing
// the same id must see each other's contribution. The preload pass runs them
// concurrently instead — `set` is a noop there, so ordering buys nothing and
// concurrency lets the `_sum` reads land in one batched load.
let buildHandlers = (config: Config.t): array<(string, string, Internal.handler)> => {
  let plansByEvent: dict<eventPlans> = Dict.make()
  config.materializations->Array.forEach(materialization => {
    let {contractName, eventName, write} = materialization->compilePlan
    let key = `${contractName}.${eventName}`
    switch plansByEvent->Utils.Dict.dangerouslyGetNonOption(key) {
    | Some(plans) => plans.writes->Array.push(write)
    | None => plansByEvent->Dict.set(key, {contractName, eventName, writes: [write]})
    }
  })

  plansByEvent
  ->Dict.valuesToArray
  ->Array.map(({contractName, eventName, writes}) => {
    let handler: Internal.handler = async args => {
      let event = args.event->(Utils.magic: Internal.event => unknown)
      if args.context.isPreload {
        let _ =
          await writes
          ->Array.map(write => write->runWrite(~event, ~context=args.context))
          ->Promise.all
      } else {
        for index in 0 to writes->Array.length - 1 {
          await writes->Array.getUnsafe(index)->runWrite(~event, ~context=args.context)
        }
      }
    }
    (contractName, eventName, handler)
  })
}
