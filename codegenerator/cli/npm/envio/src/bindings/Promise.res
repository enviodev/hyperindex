type t<+'a> = promise<'a>

@new
external make: ((@uncurry 'a => unit, 'e => unit) => unit) => t<'a> = "Promise"

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

@scope("Promise") @val
external race: array<t<'a>> => t<'a> = "race"

external done: promise<'a> => unit = "%ignore"

external unsafe_async: 'a => promise<'a> = "%identity"
external unsafe_await: promise<'a> => 'a = "?await"

let isCatchable: 'any => bool = %raw(`value => value && typeof value.catch === 'function'`)
