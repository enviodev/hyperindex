// The file with public API.
// Should be an entry point after we get rid of the generated project.
// Don't forget to keep index.d.ts in sync with this file.

@genType
type blockEvent = {number: int}

@genType
type fuelBlockEvent = {height: int}

@genType
type svmOnBlockArgs<'context> = {slot: int, context: 'context}

@genType
type onBlockArgs<'block, 'context> = {
  block: 'block,
  context: 'context,
}

@genType
type onBlockOptions<'chain> = {
  name: string,
  chain: 'chain,
  interval?: int,
  startBlock?: int,
  endBlock?: int,
}

type whereOperator<'fieldType> = {
  _eq?: 'fieldType,
  _gt?: 'fieldType,
  _lt?: 'fieldType,
}

@genType.import(("./Types.ts", "Logger"))
type logger = {
  debug: 'params. (string, ~params: {..} as 'params=?) => unit,
  info: 'params. (string, ~params: {..} as 'params=?) => unit,
  warn: 'params. (string, ~params: {..} as 'params=?) => unit,
  error: 'params. (string, ~params: {..} as 'params=?) => unit,
  errorWithExn: (string, exn) => unit,
}

@@warning("-30") // Duplicated type names (input)
@genType.import(("./Types.ts", "Effect"))
type rec effect<'input, 'output>
@genType @unboxed
and rateLimitDuration =
  | @as("second") Second
  | @as("minute") Minute
  | Milliseconds(int)
@genType @unboxed
and rateLimit =
  | @as(false) Disable
  | Enable({calls: int, per: rateLimitDuration})
@genType
and effectOptions<'input, 'output> = {
  /** The name of the effect. Used for logging and debugging. */
  name: string,
  /** The input schema of the effect. */
  input: S.t<'input>,
  /** The output schema of the effect. */
  output: S.t<'output>,
  /** Rate limit for the effect. Set to false to disable or provide {calls: number, per: "second" | "minute"} to enable. */
  rateLimit: rateLimit,
  /** Whether the effect should be cached. */
  cache?: bool,
}
@genType.import(("./Types.ts", "EffectContext"))
and effectContext = {
  log: logger,
  effect: 'input 'output. (effect<'input, 'output>, 'input) => promise<'output>,
  mutable cache: bool,
}
@genType
and effectArgs<'input> = {
  input: 'input,
  context: effectContext,
}
@@warning("+30")

let durationToMs = (duration: rateLimitDuration) =>
  switch duration {
  | Second => 1000
  | Minute => 60000
  | Milliseconds(ms) => ms
  }

let createEffect = (
  options: effectOptions<'input, 'output>,
  handler: effectArgs<'input> => promise<'output>,
) => {
  let outputSchema =
    S.schema(_ => options.output)->(Utils.magic: S.t<S.t<'output>> => S.t<Internal.effectOutput>)
  let itemSchema = S.schema((s): Internal.effectCacheItem => {
    id: s.matches(S.string),
    output: s.matches(outputSchema),
  })
  {
    name: options.name,
    handler: handler->(
      Utils.magic: (effectArgs<'input> => promise<'output>) => Internal.effectArgs => promise<
        Internal.effectOutput,
      >
    ),
    activeCallsCount: 0,
    prevCallStartTimerRef: %raw(`null`),
    // This is the way to make the createEffect API
    // work without the need for users to call S.schema themselves,
    // but simply pass the desired object/tuple/etc.
    // If they pass a schem, it'll also work.
    input: S.schema(_ => options.input)->(
      Utils.magic: S.t<S.t<'input>> => S.t<Internal.effectInput>
    ),
    output: outputSchema,
    storageMeta: {
      table: Internal.makeCacheTable(~effectName=options.name),
      outputSchema,
      itemSchema,
    },
    defaultShouldCache: switch options.cache {
    | Some(true) => true
    | _ => false
    },
    rateLimit: switch options.rateLimit {
    | Disable => None
    | Enable({calls, per}) =>
      Some({
        callsPerDuration: calls,
        durationMs: per->durationToMs,
        availableCalls: calls,
        windowStartTime: Js.Date.now(),
        queueCount: 0,
        nextWindowPromise: None,
      })
    },
  }->(Utils.magic: Internal.effect => effect<'input, 'output>)
}
