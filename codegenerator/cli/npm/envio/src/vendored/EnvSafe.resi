type t
type env = dict<string>
let make: (~env: env=?) => t
let get: (
  t,
  string,
  S.t<'a>,
  ~allowEmpty: bool=?,
  ~fallback: 'a=?,
  ~devFallback: 'a=?,
  ~input: option<string>=?,
) => 'a
let close: t => unit
