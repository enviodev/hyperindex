// What a value read back from Postgres is, not only what it prints as: a
// `1.50` that came back as a number rather than a string would otherwise pass,
// and so would a `bytea` that came back as something other than bytes.

%%private(let isDate: unknown => bool = %raw(`(value) => value instanceof Date`))

let rec shown = (value: unknown) =>
  switch value->(Utils.magic: unknown => Nullable.t<unknown>)->Nullable.toOption {
  | None => "null"
  | Some(value) =>
    if Array.isArray(value) {
      "[" ++
      value->(Utils.magic: unknown => array<unknown>)->Array.map(shown)->Array.join(", ") ++ "]"
    } else if isDate(value) {
      `date ${value->(Utils.magic: unknown => Date.t)->Date.toISOString}`
    } else {
      switch value->typeof {
      | #string => `text ${value->(Utils.magic: unknown => string)}`
      | #object =>
        switch value->Utils.Bytes.asUint8Array {
        | Some(bytes) => `bytes ${bytes->Utils.Bytes.toHex}`
        | None => `json ${JSON.stringifyAny(value)->Option.getOr("")}`
        }
      | _ => `${(value->typeof :> string)} ${String.make(value)}`
      }
    }
  }

// A row as an ordered list of its columns, so a missing or extra one shows up
// as plainly as a wrong value.
let row = (row: dict<unknown>) =>
  row->Dict.toArray->Array.map(((name, value)) => (name, shown(value)))

let rows = (rows: array<dict<unknown>>) => rows->Array.map(row)
