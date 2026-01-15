type t<+'a> = promise<'a>

@new
external make: ((@uncurry 'a => unit, 'e => unit) => unit) => t<'a> = "Promise"

@new
external makeAsync: ((@uncurry 'a => unit, 'e => unit) => promise<unit>) => t<'a> = "Promise"

@val @scope("Promise")
external resolve: 'a => t<'a> = "resolve"

@send external then: (t<'a>, @uncurry 'a => t<'b>) => t<'b> = "then"

@send
external thenResolve: (t<'a>, @uncurry 'a => 'b) => t<'b> = "then"

@send external finally: (t<'a>, unit => unit) => t<'a> = "finally"

@scope("Promise") @val
external reject: exn => t<_> = "reject"

@scope("Promise") @val
external all: array<t<'a>> => t<array<'a>> = "all"

@scope("Promise") @val
external all2: ((t<'a>, t<'b>)) => t<('a, 'b)> = "all"

@scope("Promise") @val
external all3: ((t<'a>, t<'b>, t<'c>)) => t<('a, 'b, 'c)> = "all"

@scope("Promise") @val
external all4: ((t<'a>, t<'b>, t<'c>, t<'d>)) => t<('a, 'b, 'c, 'd)> = "all"

@scope("Promise") @val
external all5: ((t<'a>, t<'b>, t<'c>, t<'d>, t<'e>)) => t<('a, 'b, 'c, 'd, 'e)> = "all"

@scope("Promise") @val
external all6: ((t<'a>, t<'b>, t<'c>, t<'d>, t<'e>, t<'f>)) => t<('a, 'b, 'c, 'd, 'e, 'f)> = "all"

@send
external catch: (t<'a>, @uncurry exn => t<'a>) => t<'a> = "catch"

%%private(let noop = (() => ())->Obj.magic)
let silentCatch = (promise: promise<'a>): promise<'a> => {
  catch(promise, noop)
}

let catch = (promise: promise<'a>, callback: exn => promise<'a>): promise<'a> => {
  catch(promise, err => {
    callback(Js.Exn.anyToExnInternal(err))
  })
}

@send
external catchResolve: (t<'a>, exn => 'a) => t<'a> = "catch"

@scope("Promise") @val
external race: array<t<'a>> => t<'a> = "race"

// Result type for allSettled
type settledResult<'a> =
  | @as("fulfilled") Fulfilled({value: 'a})
  | @as("rejected") Rejected({reason: exn})

@scope("Promise") @val
external allSettled: array<t<'a>> => t<array<settledResult<'a>>> = "allSettled"

// Helper to wait for all promises to settle, then throw first error if any failed.
// This is useful when you want Promise.all semantics (throw on first error)
// but need to ensure all promises complete first (e.g., to release connections).
let allSettledThenThrow = async (promises: array<t<'a>>): array<'a> => {
  let results = await allSettled(promises)
  let values = []
  let firstError = ref(None)

  results->Js.Array2.forEach(result => {
    switch result {
    | Fulfilled({value}) => values->Js.Array2.push(value)->ignore
    | Rejected({reason}) =>
      if firstError.contents === None {
        firstError := Some(reason)
      }
    }
  })

  switch firstError.contents {
  | Some(error) => raise(error)
  | None => values
  }
}

external done: promise<'a> => unit = "%ignore"

external ignoreValue: promise<'a> => promise<unit> = "%identity"

external unsafe_async: 'a => promise<'a> = "%identity"
external unsafe_await: promise<'a> => 'a = "?await"

let isCatchable: 'any => bool = %raw(`value => value && typeof value.catch === 'function'`)
