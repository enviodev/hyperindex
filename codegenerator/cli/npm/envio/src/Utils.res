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

  let merge: (dict<'a>, dict<'a>) => dict<'a> = %raw(`(dictA, dictB) => ({...dictA, ...dictB})`)

  let updateImmutable: (
    dict<'a>,
    string,
    'a,
  ) => dict<'a> = %raw(`(dict, key, value) => ({...dict, [key]: value})`)
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

  /**
  Creates a shallow copy of the array and sets the value at the given index
  */
  let setIndexImmutable = (arr: array<'a>, index: int, value: 'a): array<'a> => {
    let shallowCopy = arr->Belt.Array.copy
    shallowCopy->Js.Array2.unsafe_set(index, value)
    shallowCopy
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
      Belt.Array.concat(head, tail)
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

  /**
  Interleaves an array with a separator

  interleave([1, 2, 3], 0) -> [1, 0, 2, 0, 3]
  */
  let interleave = (arr: array<'a>, separator: 'a) => {
    let interleaved = []
    arr->Js.Array2.forEachi((v, i) => {
      interleaved->Js.Array2.push(v)->ignore
      if i < arr->Array.length - 1 {
        interleaved->Js.Array2.push(separator)->ignore
      }
    })
    interleaved
  }
}

module String = {
  let capitalize = str => {
    str->Js.String2.slice(~from=0, ~to_=1)->Js.String.toUpperCase ++
      str->Js.String2.sliceToEnd(~from=1)
  }
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

module Schema = {
  let enum = items => S.union(items->Belt.Array.mapU(S.literal))

  let getNonOptionalFieldNames = schema => {
    let acc = []
    switch schema->S.classify {
    | Object({items}) =>
      items->Js.Array2.forEach(item => {
        switch item.schema->S.classify {
        // Check for null, since we generate S.null schema for db serializing
        // In the future it should be changed to Option
        | Null(_) => ()
        | _ => acc->Js.Array2.push(item.location)->ignore
        }
      })
    | _ => ()
    }
    acc
  }

  let getCapitalizedFieldNames = schema => {
    switch schema->S.classify {
    | Object({items}) => items->Js.Array2.map(item => item.location->String.capitalize)
    | _ => []
    }
  }

  // When trying to serialize data to Json pg type, it will fail with
  // PostgresError: column "params" is of type json but expression is of type boolean
  // If there's bool or null on the root level. It works fine as object field values.
  let coerceToJsonPgType = schema => {
    schema->S.preprocess(s => {
      switch s.schema->S.classify {
      | Literal(Null(_))
      | // This is a workaround for Fuel Bytes type
      Unknown => {serializer: _ => %raw(`"null"`)}
      | Null(_)
      | Bool => {
          serializer: unknown => {
            if unknown === %raw(`null`) {
              %raw(`"null"`)
            } else if unknown === %raw(`false`) {
              %raw(`"false"`)
            } else if unknown === %raw(`true`) {
              %raw(`"true"`)
            } else {
              unknown
            }
          },
        }
      | _ => {}
      }
    })
  }
}

module Set = {
  type t<'value>

  /*
   * Constructor
   */
  @ocaml.doc("Creates a new `Set` object.") @new
  external make: unit => t<'value> = "Set"

  @ocaml.doc("Creates a new `Set` object.") @new
  external fromEntries: array<'value> => t<'value> = "Set"

  /*
   * Instance properties
   */
  @ocaml.doc("Returns the number of values in the `Set` object.") @get
  external size: t<'value> => int = "size"

  /*
   * Instance methods
   */
  @ocaml.doc("Appends `value` to the `Set` object. Returns the `Set` object with added value.")
  @send
  external add: (t<'value>, 'value) => t<'value> = "add"

  @ocaml.doc("Removes all elements from the `Set` object.") @send
  external clear: t<'value> => unit = "clear"

  @ocaml.doc(
    "Removes the element associated to the `value` and returns a boolean asserting whether an element was successfully removed or not. `Set.prototype.has(value)` will return `false` afterwards."
  )
  @send
  external delete: (t<'value>, 'value) => bool = "delete"

  @ocaml.doc(
    "Returns a boolean asserting whether an element is present with the given value in the `Set` object or not."
  )
  @send
  external has: (t<'value>, 'value) => bool = "has"

  external toArray: t<'a> => array<'a> = "Array.from"

  /*
   * Iteration methods
   */
  /*
/// NOTE - if we need iteration we can add this back - currently it requires the `rescript-js-iterator` library.
@ocaml.doc(
  "Returns a new iterator object that yields the **values** for each element in the `Set` object in insertion order."
)
@send
external values: t<'value> => Js_iterator.t<'value> = "values"

@ocaml.doc("An alias for `Set.prototype.values()`.") @send
external keys: t<'value> => Js_iterator.t<'value> = "values"

@ocaml.doc("Returns a new iterator object that contains **an array of [value, value]** for each element in the `Set` object, in insertion order.

This is similar to the [Map](https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/Map) object, so that each entry's `key` is the same as its `value` for a `Set`.")
@send
external entries: t<'value> => Js_iterator.t<('value, 'value)> = "entries"
*/
  @ocaml.doc(
    "Calls `callbackFn` once for each value present in the `Set` object, in insertion order."
  )
  @send
  external forEach: (t<'value>, 'value => unit) => unit = "forEach"

  @ocaml.doc(
    "Calls `callbackFn` once for each value present in the `Set` object, in insertion order."
  )
  @send
  external forEachWithSet: (t<'value>, ('value, 'value, t<'value>) => unit) => unit = "forEach"
}

module WeakMap = {
  type t<'k, 'v> = Js.WeakMap.t<'k, 'v>

  @new external make: unit => t<'k, 'v> = "WeakMap"

  @send external get: (t<'k, 'v>, 'k) => option<'v> = "get"
  @send external unsafeGet: (t<'k, 'v>, 'k) => 'v = "get"
  @send external has: (t<'k, 'v>, 'k) => bool = "has"
  @send external set: (t<'k, 'v>, 'k, 'v) => t<'k, 'v> = "set"
}
