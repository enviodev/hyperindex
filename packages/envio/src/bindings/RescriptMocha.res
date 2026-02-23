module Assert = {
  type assertion<'a> = ('a, 'a, ~message: string=?) => unit

  @module("assert") external equal: assertion<'a> = "equal"
  @module("assert") external notEqual: assertion<'a> = "notEqual"

  @module("assert") external deepEqual: assertion<'a> = "deepEqual"
  @module("assert")
  external notDeepEqual: assertion<'a> = "notDeepEqual"

  @module("assert") external strictEqual: assertion<'a> = "strictEqual"
  @module("assert")
  external notStrictEqual: assertion<'a> = "notStrictEqual"

  @module("assert")
  external deepStrictEqual: assertion<'a> = "deepStrictEqual"
  @module("assert")
  external notDeepStrictEqual: assertion<'a> = "notDeepStrictEqual"

  @module("assert") external ifError: 'a => unit = "ifError"

  @module("assert")
  external throws: (unit => 'a, ~error: 'error=?, ~message: string=?) => unit = "throws"
  @module("assert")
  external doesNotThrow: (unit => 'a, ~error: 'error=?, ~message: string=?) => unit = "doesNotThrow"

  @module("assert")
  external rejects: (unit => promise<'a>, ~error: 'error=?, ~message: string=?) => promise<unit> =
    "rejects"

  @module("assert") external ok: (bool, ~message: string=?) => unit = "ok"
  @module("assert") external fail: string => 'a = "fail"
}

/* Mocha bindings on `this` for `describe` and `it` functions */
module This = {
  @val external timeout: int => unit = "this.timeout"
  @val external retries: int => unit = "this.retries"
  @val external slow: int => unit = "this.slow"
  @val external skip: unit => unit = "this.skip"
}

@val
external describe: (string, unit => unit) => unit = "describe"
@val
external describe_only: (string, unit => unit) => unit = "describe.only"
@val
external describe_skip: (string, unit => unit) => unit = "describe.skip"

@val
external it: (string, unit => unit) => unit = "it"
@val
external it_only: (string, unit => unit) => unit = "it.only"
@val
external it_skip: (string, unit => unit) => unit = "it.skip"
@val
external before: (unit => unit) => unit = "before"
@val
external after: (unit => unit) => unit = "after"
@val
external beforeEach: (unit => unit) => unit = "beforeEach"
@val
external afterEach: (unit => unit) => unit = "afterEach"
@val
external beforeWithTitle: (string, unit => unit) => unit = "before"
@val
external afterWithTitle: (string, unit => unit) => unit = "after"
@val
external beforeEachWithTitle: (string, unit => unit) => unit = "beforeEach"
@val
external afterEachWithTitle: (string, unit => unit) => unit = "afterEach"

module Async = {
  @val
  external it: (string, unit => promise<unit>) => unit = "it"
  @val
  external it_only: (string, unit => promise<unit>) => unit = "it.only"
  @val
  external it_skip: (string, unit => promise<unit>) => unit = "it.skip"
  @val
  external before: (unit => promise<unit>) => unit = "before"
  @val
  external after: (unit => promise<unit>) => unit = "after"
  @val
  external beforeEach: (unit => promise<unit>) => unit = "beforeEach"
  @val
  external afterEach: (unit => promise<unit>) => unit = "afterEach"
  @val
  external beforeWithTitle: (string, unit => promise<unit>) => unit = "before"
  @val
  external afterWithTitle: (string, unit => promise<unit>) => unit = "after"
  @val
  external beforeEachWithTitle: (string, unit => promise<unit>) => unit = "beforeEach"
  @val
  external afterEachWithTitle: (string, unit => promise<unit>) => unit = "afterEach"
}

module DoneCallback = {
  type doneCallback = Js.Nullable.t<Js.Exn.t> => unit

  @val
  external it: (string, doneCallback => unit) => unit = "it"
  @val
  external it_only: (string, doneCallback => unit) => unit = "it.only"
  @val
  external it_skip: (string, doneCallback => unit) => unit = "it.skip"
  @val
  external before: (doneCallback => unit) => unit = "before"
  @val
  external after: (doneCallback => unit) => unit = "after"
  @val
  external beforeEach: (doneCallback => unit) => unit = "beforeEach"
  @val
  external afterEach: (doneCallback => unit) => unit = "afterEach"
  @val
  external beforeWithTitle: (string, doneCallback => unit) => unit = "before"
  @val
  external afterWithTitle: (string, doneCallback => unit) => unit = "after"
  @val
  external beforeEachWithTitle: (string, doneCallback => unit) => unit = "beforeEach"
  @val
  external afterEachWithTitle: (string, doneCallback => unit) => unit = "afterEach"
}
