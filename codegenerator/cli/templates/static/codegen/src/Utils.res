external magic: 'a => 'b = "%identity"

module Option = {
  let mapNone = (opt: option<'a>, val: 'b): option<'b> => {
    switch opt {
    | None => Some(val)
    | Some(_) => None
    }
  }

  let catchToNone: (unit => 'a) => option<'a> = unsafeFunc => {
    try {
      unsafeFunc()->Some
    } catch {
    | _ => None
    }
  }

  let flatten = opt =>
    switch opt {
    | None => None
    | Some(opt) => opt
    }

  let getExn = (opt, message) => {
    switch opt {
    | None => Js.Exn.raiseError(message)
    | Some(v) => v
    }
  }
}

module Tuple = {
  /**Access a tuple value by its index*/
  @warning("-27")
  let get = (tuple: 'a, index: int): option<'b> => %raw(`tuple[index]`)
}

module Dict = {
  @get_index
  /**
    It's the same as `Js.Dict.get` but it doesn't have runtime overhead to check if the key exists.
   */
  external dangerouslyGetNonOption: (dict<'a>, string) => option<'a> = ""
}

module Math = {
  let minOptInt = (a, b) =>
    switch (a, b) {
    | (Some(a), Some(b)) => Pervasives.min(a, b)->Some
    | (Some(a), None) => Some(a)
    | (None, Some(b)) => Some(b)
    | (None, None) => None
    }
}
module Array = {
  @val external jsArrayCreate: int => array<'a> = "Array"

  /* Given a comaprator and two sorted lists, combine them into a single sorted list */
  let mergeSorted = (f: ('a, 'a) => bool, xs: array<'a>, ys: array<'a>) => {
    if Array.length(xs) == 0 {
      ys
    } else if Array.length(ys) == 0 {
      xs
    } else {
      let n = Array.length(xs) + Array.length(ys)
      let result = jsArrayCreate(n)

      let rec loop = (i, j, k) => {
        if i < Array.length(xs) && j < Array.length(ys) {
          if f(xs[i], ys[j]) {
            result[k] = xs[i]
            loop(i + 1, j, k + 1)
          } else {
            result[k] = ys[j]
            loop(i, j + 1, k + 1)
          }
        } else if i < Array.length(xs) {
          result[k] = xs[i]
          loop(i + 1, j, k + 1)
        } else if j < Array.length(ys) {
          result[k] = ys[j]
          loop(i, j + 1, k + 1)
        }
      }

      loop(0, 0, 0)
      result
    }
  }

  let transposeResults = (results: array<result<'a, 'b>>): result<array<'a>, 'b> => {
    let rec loop = (index: int, output: array<'a>): result<array<'a>, 'b> => {
      if index >= Array.length(results) {
        Ok(output)
      } else {
        switch results->Js.Array2.unsafe_get(index) {
        | Ok(value) => {
            output[index] = value
            loop(index + 1, output)
          }
        | Error(_) as err => err->(magic: result<'a, 'b> => result<array<'a>, 'b>)
        }
      }
    }

    loop(0, Belt.Array.makeUninitializedUnsafe(results->Js.Array2.length))
  }

  /**
Helper to check if a value exists in an array
*/
  let includes = (arr: array<'a>, val: 'a) =>
    arr->Js.Array2.find(item => item == val)->Belt.Option.isSome

  let isEmpty = (arr: array<_>) =>
    switch arr {
    | [] => true
    | _ => false
    }

  let awaitEach = async (arr: array<'a>, fn: 'a => promise<unit>) => {
    for i in 0 to arr->Array.length - 1 {
      let item = arr[i]
      await item->fn
    }
  }

  /**
  Creates a new array removing the item at the given index

  Index > array length or < 0 results in a copy of the array
  */
  let removeAtIndex = (array, index) => {
    if index < 0 || index >= array->Array.length {
      array->Array.copy
    } else {
      let head = array->Js.Array2.slice(~start=0, ~end_=index)
      let tail = array->Belt.Array.sliceToEnd(index + 1)
      [...head, ...tail]
    }
  }

  let last = (arr: array<'a>): option<'a> => arr->Belt.Array.get(arr->Array.length - 1)

  let findReverseWithIndex = (arr: array<'a>, fn: 'a => bool): option<('a, int)> => {
    let rec loop = (index: int) => {
      if index < 0 {
        None
      } else {
        let item = arr[index]
        if fn(item) {
          Some((item, index))
        } else {
          loop(index - 1)
        }
      }
    }
    loop(arr->Array.length - 1)
  }

  /** 
  Currently a bug in rescript if you ignore the return value of spliceInPlace 
  https://github.com/rescript-lang/rescript-compiler/issues/6991
  */
  @send
  external spliceInPlace: (array<'a>, ~pos: int, ~remove: int) => array<'a> = "splice"
}

/**
Useful when an unsafe unwrap is needed on Result type
and Error holds an exn. This is better than Result.getExn
because the excepion is not just NOT_FOUND but will rather
bet the actual underlying exn
*/
let unwrapResultExn = res =>
  switch res {
  | Ok(v) => v
  | Error(exn) => exn->raise
  }

external queueMicrotask: (unit => unit) => unit = "queueMicrotask"
