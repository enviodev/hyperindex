// The file with public API.
// Should be an entry point after we get rid of the generated project.
// Don't forget to keep index.d.ts in sync with this file.

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
@genType
and effectOptions<'input, 'output> = {
  /** The name of the effect. Used for logging and debugging. */
  name: string,
  /** The input schema of the effect. */
  input: S.t<'input>,
  /** The output schema of the effect. */
  output: S.t<'output>,
  /** Whether the effect should be cached. */
  cache?: bool,
}
@genType.import(("./Types.ts", "EffectContext"))
and effectContext = {
  log: logger,
  effect: 'input 'output. (effect<'input, 'output>, 'input) => promise<'output>,
}
@genType
and effectArgs<'input> = {
  input: 'input,
  context: effectContext,
}
@@warning("+30")

let experimental_createEffect = (
  options: effectOptions<'input, 'output>,
  handler: effectArgs<'input> => promise<'output>,
) => {
  Prometheus.EffectCallsCount.set(~callsCount=0, ~effectName=options.name)
  let outputSchema =
    S.schema(_ => options.output)->(Utils.magic: S.t<S.t<'output>> => S.t<Internal.effectOutput>)
  {
    name: options.name,
    handler: handler->(
      Utils.magic: (effectArgs<'input> => promise<'output>) => Internal.effectArgs => promise<
        Internal.effectOutput,
      >
    ),
    callsCount: 0,
    // This is the way to make the createEffect API
    // work without the need for users to call S.schema themselves,
    // but simply pass the desired object/tuple/etc.
    // If they pass a schem, it'll also work.
    input: S.schema(_ => options.input)->(
      Utils.magic: S.t<S.t<'input>> => S.t<Internal.effectInput>
    ),
    output: outputSchema,
    cache: switch options.cache {
    | Some(true) =>
      let itemSchema = S.schema((s): Internal.effectCacheItem => {
        id: s.matches(S.string),
        output: s.matches(outputSchema),
      })
      Some({
        table: Internal.makeCacheTable(~effectName=options.name),
        rowsSchema: S.array(itemSchema),
        itemSchema,
      })
    | None
    | Some(false) =>
      None
    },
  }->(Utils.magic: Internal.effect => effect<'input, 'output>)
}
