external magic: 'a => 'b = "%identity"

@val external jsArrayCreate: int => array<'a> = "Array"

/* Given a comaprator and two sorted lists, combine them into a single sorted list */
let mergeSorted = (f: 'a => 'b, xs: array<'a>, ys: array<'a>) => {
  if Array.length(xs) == 0 {
    ys
  } else if Array.length(ys) == 0 {
    xs
  } else {
    let n = Array.length(xs) + Array.length(ys)
    let result = jsArrayCreate(n)

    let rec loop = (i, j, k) => {
      if i < Array.length(xs) && j < Array.length(ys) {
        if f(xs[i]) <= f(ys[j]) {
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

type promiseWithHandles<'a> = {
  pendingPromise: promise<'a>,
  resolve: 'a => unit,
  reject: exn => unit,
}

let createPromiseWithHandles = () => {
  //Create a placeholder resovle
  let resolveRef = ref(None)
  let rejectRef = ref(None)

  let pendingPromise = Promise.make((resolve, reject) => {
    resolveRef := Some(resolve)
    rejectRef := Some(reject)
  })

  let resolve = (val: 'a) => {
    let res = resolveRef.contents->Belt.Option.getUnsafe
    res(. val)
  }

  let reject = (exn: exn) => {
    let rej = rejectRef.contents->Belt.Option.getUnsafe
    rej(. exn)
  }

  {
    pendingPromise,
    resolve,
    reject,
  }
}

let mapArrayOfResults = (results: array<result<'a, 'b>>): result<array<'a>, 'b> => {
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

let optionMapNone = (opt: option<'a>, val: 'b): option<'b> => {
  switch opt {
  | None => Some(val)
  | Some(_) => None
  }
}

module Option = {
  let flatten = opt => switch opt {
  | None => None
  | Some(opt) => opt
  }
}

module Tuple = {
  /**Access a tuple value by its index*/
  @warning("-27")
  let get = (tuple: 'a, index: int): option<'b> => %raw(`tuple[index]`)
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

/**
Helper to check if a value exists in an array
*/
let arrayIncludes = (arr: array<'a>, val: 'a) =>
  arr->Js.Array2.find(item => item == val)->Belt.Option.isSome

let awaitEach = async (arr: array<'a>, fn: 'a => promise<unit>) => {
  for i in 0 to arr->Array.length - 1 {
    let item = arr[i]
    await item->fn
  }
}
