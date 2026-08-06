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

open MaterializationPlan

@get_index external field: (unknown, string) => unknown = ""

// Plans are compiled to closures once at startup, so per-event work is a call.
type eval = unknown => unknown
type predicate = unknown => bool

let throwInvalid = (message): 'a =>
  JsError.throwWithMessage(`Invalid indexer config: ${message} Run \`envio codegen\` again.`)

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

let rec compileExpr = (expr: expr): eval =>
  switch expr {
  | Path([only]) => event => event->field(only)
  | Path(path) => event => path->Array.reduce(event, field)
  | LitString(value) =>
    let value = value->(Utils.magic: string => unknown)
    _ => value
  | LitBool(value) =>
    let value = value->(Utils.magic: bool => unknown)
    _ => value
  | LitNumber(value) =>
    let value = value->(Utils.magic: float => unknown)
    _ => value
  | LitBigInt(text) =>
    let value = text->bigIntOfString->(Utils.magic: bigint => unknown)
    _ => value
  | LitBigDecimal(text) =>
    let value = text->bigDecimalOfString->(Utils.magic: BigDecimal.t => unknown)
    _ => value
  | LitNull => _ => %raw(`null`)
  | Negate(numeric, inner) =>
    let inner = inner->compileExpr
    event => numeric->negate(inner(event))
  | Concat(separator, values) =>
    let separator = separator->Option.getOr("")
    let parts = values->Array.map(compileExpr)
    event =>
      parts
      ->Array.map(part => part(event)->toText)
      ->Array.joinUnsafe(separator)
      ->(Utils.magic: string => unknown)
  }

// The operator is fixed when the plan is compiled, so the comparison is picked
// once here rather than re-dispatched on every event.
let compileComparison = (op: comparison): ((unknown, unknown) => bool) =>
  switch op {
  | Eq => %raw(`(a, b) => a == b`)
  | Ne => %raw(`(a, b) => a != b`)
  | Gt => %raw(`(a, b) => a > b`)
  | Gte => %raw(`(a, b) => a >= b`)
  | Lt => %raw(`(a, b) => a < b`)
  | Lte => %raw(`(a, b) => a <= b`)
  }

let rec compileFilter = (filter: filter): predicate =>
  switch filter {
  | And(filters) =>
    let parts = filters->Array.map(compileFilter)
    event => parts->Array.every(part => part(event))
  | Or(filters) =>
    let parts = filters->Array.map(compileFilter)
    event => parts->Array.some(part => part(event))
  | Cmp(path, op, value) =>
    let left = Path(path)->compileExpr
    let right = value->compileExpr
    let compare = op->compileComparison
    event => compare(left(event), right(event))
  | In({path, negated, values}) =>
    let left = Path(path)->compileExpr
    let candidates = values->Array.map(compileExpr)
    let equals = Eq->compileComparison
    event => {
      let value = left(event)
      candidates->Array.some(candidate => equals(value, candidate(event))) !== negated
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

let compileWrite = (plan: MaterializationPlan.t): write => {
  let setFields = []
  let sumFields = []
  plan.fields->Array.forEach(field =>
    switch field {
    | Set({name, expr}) => setFields->Array.push((name, expr->compileExpr))
    | Sum({name, numeric, expr}) => sumFields->Array.push((name, numeric, expr->compileExpr))
    }
  )
  {
    table: plan.table,
    filter: plan.filter->Option.map(compileFilter),
    id: plan.id->compileExpr,
    setFields,
    sumFields,
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

// What `HandlerRegister` needs to install one materializer handler.
type registration = {
  contractName: string,
  eventName: string,
  wildcard: bool,
  handler: Internal.handler,
}

type eventPlans = {
  contractName: string,
  eventName: string,
  wildcard: bool,
  writes: array<write>,
}

// One handler per (contract, event, wildcard), running every plan that event
// feeds in config order. Sequential on the execute pass on purpose: two plans
// writing the same id must see each other's contribution. The preload pass runs
// them concurrently instead — `set` is a noop there, so ordering buys nothing
// and concurrency lets the `_sum` reads land in one batched load.
let buildHandlers = (config: Config.t): array<registration> => {
  let plansByEvent: dict<eventPlans> = Dict.make()
  config.materializations->Array.forEach(plan => {
    // A wildcard and an address-bound table on one event need separate
    // registrations, or the wildcard's rows would be limited to the configured
    // addresses (or vice versa).
    let key = `${plan.contractName}.${plan.eventName}.${plan.wildcard ? "wildcard" : "addresses"}`
    let write = plan->compileWrite
    switch plansByEvent->Utils.Dict.dangerouslyGetNonOption(key) {
    | Some(plans) => plans.writes->Array.push(write)
    | None =>
      plansByEvent->Dict.set(
        key,
        {
          contractName: plan.contractName,
          eventName: plan.eventName,
          wildcard: plan.wildcard,
          writes: [write],
        },
      )
    }
  })

  plansByEvent
  ->Dict.valuesToArray
  ->Array.map(({contractName, eventName, wildcard, writes}) => {
    let handler: Internal.handler = async args => {
      let event = args.event->(Utils.magic: Internal.event => unknown)
      if args.context.isPreload {
        let _ = await writes
        ->Array.map(write => write->runWrite(~event, ~context=args.context))
        ->Promise.all
      } else {
        for index in 0 to writes->Array.length - 1 {
          await writes->Array.getUnsafe(index)->runWrite(~event, ~context=args.context)
        }
      }
    }
    {contractName, eventName, wildcard, handler}
  })
}
