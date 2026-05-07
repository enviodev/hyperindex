@@uncurried

type env
type t

let make: (~env: env=?) => t

let close: t => unit

let get: (
  t,
  string,
  S.t<'value>,
  ~allowEmpty: bool=?,
  ~fallback: 'value=?,
  ~devFallback: 'value=?,
  ~input: option<string>=?,
) => 'value
