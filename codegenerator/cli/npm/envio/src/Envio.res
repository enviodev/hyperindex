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
  /** The handler function that will be called when the effect is executed. */
  handler: effectArgs<'input> => promise<'output>,
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

let createEffect = options => {
  options->(Utils.magic: Internal.effect => effect<'input, 'output>)
}
