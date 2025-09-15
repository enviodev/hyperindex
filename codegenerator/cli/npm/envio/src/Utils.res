external magic: 'a => 'b = "%identity"

let delay = milliseconds =>
  Js.Promise2.make((~resolve, ~reject as _) => {
    let _interval = Js.Global.setTimeout(_ => {
      resolve()
    }, milliseconds)
  })

module Object = {
  // Define a type for the property descriptor
  type propertyDescriptor<'a> = {
    configurable?: bool,
    enumerable?: bool,
    writable?: bool,
    value?: 'a,
    get?: unit => 'a,
    set?: 'a => unit,
  }

  @val @scope("Object")
  external defineProperty: ('obj, string, propertyDescriptor<'a>) => 'obj = "defineProperty"
}

module Error = {
  @new
  external make: string => exn = "Error"
}

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

module Dict = {
  @get_index
  /**
    It's the same as `Js.Dict.get` but it doesn't have runtime overhead to check if the key exists.
   */
  external dangerouslyGetNonOption: (dict<'a>, string) => option<'a> = ""

  let has: (dict<'a>, string) => bool = %raw(`(dict, key) => key in dict`)

  let push = (dict, key, value) => {
    switch dict->dangerouslyGetNonOption(key) {
    | Some(arr) => arr->Js.Array2.push(value)->ignore
    | None => dict->Js.Dict.set(key, [value])
    }
  }

  let pushMany = (dict, key, values) => {
    switch dict->dangerouslyGetNonOption(key) {
    | Some(arr) => arr->Js.Array2.pushMany(values)->ignore
    | None => dict->Js.Dict.set(key, values)
    }
  }

  let merge: (dict<'a>, dict<'a>) => dict<'a> = %raw(`(dictA, dictB) => ({...dictA, ...dictB})`)

  @val
  external mergeInPlace: (dict<'a>, dict<'a>) => dict<'a> = "Object.assign"

  let map = (dict, fn) => {
    let newDict = Js.Dict.empty()
    let keys = dict->Js.Dict.keys
    for idx in 0 to keys->Js.Array2.length - 1 {
      let key = keys->Js.Array2.unsafe_get(idx)
      newDict->Js.Dict.set(key, fn(dict->Js.Dict.unsafeGet(key)))
    }
    newDict
  }

  let forEach = (dict, fn) => {
    let keys = dict->Js.Dict.keys
    for idx in 0 to keys->Js.Array2.length - 1 {
      fn(dict->Js.Dict.unsafeGet(keys->Js.Array2.unsafe_get(idx)))
    }
  }

  let forEachWithKey = (dict, fn) => {
    let keys = dict->Js.Dict.keys
    for idx in 0 to keys->Js.Array2.length - 1 {
      let key = keys->Js.Array2.unsafe_get(idx)
      fn(key, dict->Js.Dict.unsafeGet(key))
    }
  }

  let deleteInPlace: (dict<'a>, string) => unit = %raw(`(dict, key) => {
      delete dict[key];
    }
  `)

  let updateImmutable: (
    dict<'a>,
    string,
    'a,
  ) => dict<'a> = %raw(`(dict, key, value) => ({...dict, [key]: value})`)

  let shallowCopy: dict<'a> => dict<'a> = %raw(`(dict) => ({...dict})`)

  let size = dict => dict->Js.Dict.keys->Js.Array2.length

  @set_index
  external setByInt: (dict<'a>, int, 'a) => unit = ""

  let incrementByInt: (dict<int>, int) => unit = %raw(`(dict, key) => {
    dict[key]++
  }`)
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

module Cmp = {
  type cmpFn<'a> = ('a, 'a) => int
  type boolFn<'a> = ('a, 'a) => bool

  type t<'a> = {
    cmp: cmpFn<'a>,
    eq: boolFn<'a>,
    lt: boolFn<'a>,
    lte: boolFn<'a>,
    gt: boolFn<'a>,
    gte: boolFn<'a>,
  }

  let make = (~cmp: cmpFn<'a>, ~eq: boolFn<'a>): t<'a> => {
    cmp,
    eq,
    lt: (a, b) => cmp(a, b) < 0,
    lte: (a, b) => cmp(a, b) <= 0,
    gt: (a, b) => cmp(a, b) > 0,
    gte: (a, b) => cmp(a, b) >= 0,
  }

  let int: t<int> = make(~cmp=(a, b) => a - b, ~eq=(a, b) => a === b)
  let float: t<float> = make(~cmp=(a, b) => (a -. b)->Belt.Float.toInt, ~eq=(a, b) => a === b)
  let string: t<string> = make(~cmp=(a, b) => String.compare(a, b), ~eq=(a, b) => a === b)
}

module Array = {
  @send
  external forEachAsync: (array<'a>, 'a => promise<unit>) => unit = "forEach"

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

  let notEmpty = (arr: array<_>) =>
    switch arr {
    | [] => false
    | _ => true
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
    if index < 0 {
      array->Array.copy
    } else {
      array
      ->Js.Array2.slice(~start=0, ~end_=index)
      ->Js.Array2.concat(array->Js.Array2.sliceFrom(index + 1))
    }
  }

  let last = (arr: array<'a>): option<'a> => arr->Belt.Array.get(arr->Array.length - 1)

  let lastUnsafe = (arr: array<'a>): 'a => arr->Belt.Array.getUnsafe(arr->Array.length - 1)

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

  @send
  external flatten: (array<array<'a>>, @as(1) _) => array<'a> = "flat"

  @send
  external copy: array<'a> => array<'a> = "slice"

  /**
  Assumes that the arrays have items from idx up to maxIdx
  */
  let rec cmpInternalUnsafe = (a, b, ~cmpInner, ~idx, ~maxIdx) => {
    let itemA = a->Js.Array2.unsafe_get(idx)
    let itemB = b->Js.Array2.unsafe_get(idx)
    let val = cmpInner(itemA, itemB)
    if val == 0 && idx < maxIdx {
      cmpInternalUnsafe(a, b, ~cmpInner, ~idx=idx + 1, ~maxIdx)
    } else {
      val
    }
  }

  let cmp = (a: array<'a>, b: array<'a>, ~cmp) => {
    let aLen = a->Array.length
    let bLen = b->Array.length
    let lenDiff = aLen - bLen

    // If either of them are empty, return the difference
    if aLen == 0 || bLen == 0 {
      lenDiff
    } else if lenDiff == 0 {
      // If they are not empty and have the same length, compare them
      // unsafely up to their length and return
      cmpInternalUnsafe(a, b, ~cmpInner=cmp, ~idx=0, ~maxIdx=aLen)
    } else {
      // If they are not the same length, compare them up to the length
      // of the shortest one. If they are equal up to that length, return
      // the difference
      let maxIdx = Pervasives.min(aLen, bLen) - 1
      let val = cmpInternalUnsafe(a, b, ~cmpInner=cmp, ~idx=0, ~maxIdx)
      if val == 0 {
        lenDiff
      } else {
        val
      }
    }
  }

  /**
  Assumes that the arrays have items from idx up to maxIdx
  */
  let rec eqInternalUnsafe = (a, b, ~eqInner, ~idx, ~maxIdx) => {
    let itemA = a->Js.Array2.unsafe_get(idx)
    let itemB = b->Js.Array2.unsafe_get(idx)
    let val = eqInner(itemA, itemB)
    if val && idx < maxIdx {
      eqInternalUnsafe(a, b, ~eqInner, ~idx=idx + 1, ~maxIdx)
    } else {
      val
    }
  }

  let eq = (a: array<'a>, b: array<'a>, ~eq) => {
    let aLen = a->Array.length
    let lenDiff = aLen - b->Array.length

    // If they are not the same length, return false
    if lenDiff != 0 {
      false
    } else if aLen == 0 {
      // They are the same length, if empty return true
      true
    } else {
      // If they are not empty and have the same length, compare them
      // unsafely up to their length and return
      eqInternalUnsafe(a, b, ~eqInner=eq, ~idx=0, ~maxIdx=aLen - 1)
    }
  }

  let makeArrayCmp = (c: Cmp.t<'a>): Cmp.t<array<'a>> => {
    let cmp = (a: array<'a>, b: array<'a>) => cmp(a, b, ~cmp=c.cmp)
    let eq = (a: array<'a>, b: array<'a>) => eq(a, b, ~eq=c.eq)
    Cmp.make(~cmp, ~eq)
  }

  let int = makeArrayCmp(Cmp.int)
  let float = makeArrayCmp(Cmp.float)
  let string = makeArrayCmp(Cmp.string)
}

module Tuple = {
  /**Access a tuple value by its index*/
  @warning("-27")
  let get = (tuple: 'a, index: int): option<'b> => %raw(`tuple[index]`)

  %%private(
    /**
  For tuples of ints
  */
    let makeTupleIntCmp = (~tupleLen: int): Cmp.t<'a> => {
      let toArray = (tuple: 'a) => tuple->(magic: 'a => array<int>)
      Cmp.make(
        ~cmp=(a, b) =>
          // Can directly use unsafe comparison since tuples
          // will have the same length enforced (and won't be empty)
          Array.cmpInternalUnsafe(
            a->toArray,
            b->toArray,
            ~cmpInner=Cmp.int.cmp,
            ~maxIdx=tupleLen - 1,
            ~idx=0,
          ),
        ~eq=(a, b) =>
          Array.eqInternalUnsafe(
            a->toArray,
            b->toArray,
            ~eqInner=Cmp.int.eq,
            ~maxIdx=tupleLen - 1,
            ~idx=0,
          ),
      )
    }
  )

  let int2: Cmp.t<(int, int)> = makeTupleIntCmp(~tupleLen=2)
  let int3: Cmp.t<(int, int, int)> = makeTupleIntCmp(~tupleLen=3)
  let int4: Cmp.t<(int, int, int, int)> = makeTupleIntCmp(~tupleLen=4)
}

let check = Tuple.int4.lte((1, 2, 3, 4), (1, 2, 3, 5))

module String = {
  let capitalize = str => {
    str->Js.String2.slice(~from=0, ~to_=1)->Js.String.toUpperCase ++
      str->Js.String2.sliceToEnd(~from=1)
  }

  /**
`replaceAll(str, substr, newSubstr)` returns a new `string` which is
identical to `str` except with all matching instances of `substr` replaced
by `newSubstr`. `substr` is treated as a verbatim string to match, not a
regular expression.
See [`String.replaceAll`](https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/String/replaceAll) on MDN.

## Examples

```rescript
String.replaceAll("old old string", "old", "new") == "new new string"
String.replaceAll("the cat and the dog", "the", "this") == "this cat and this dog"
```
*/
  @send
  external replaceAll: (string, string, string) => string = "replaceAll"
}

module Result = {
  let forEach = (result, fn) => {
    switch result {
    | Ok(v) => fn(v)
    | Error(_) => ()
    }
    result
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
  let variantTag = S.union([S.string, S.object(s => s.field("TAG", S.string))])

  let getNonOptionalFieldNames = schema => {
    let acc = []
    switch schema->S.classify {
    | Object({items}) =>
      items->Js.Array2.forEach(item => {
        switch item.schema->S.classify {
        // Check for null, since we generate S.null schema for db serializing
        // In the future it should be changed to Option only
        | Null(_) => ()
        | Option(_) => ()
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

  // Don't use S.unknown, since it's not serializable to json
  // In a nutshell, this is completely unsafe.
  let dbDate =
    S.json(~validate=false)
    ->(magic: S.t<Js.Json.t> => S.t<Js.Date.t>)
    ->S.preprocess(_ => {serializer: date => date->magic->Js.Date.toISOString})

  // When trying to serialize data to Json pg type, it will fail with
  // PostgresError: column "params" is of type json but expression is of type boolean
  // If there's bool or null on the root level. It works fine as object field values.
  let coerceToJsonPgType = schema => {
    schema->S.preprocess(s => {
      switch s.schema->S.classify {
      // This is a workaround for Fuel Bytes type
      | Unknown => {serializer: _ => %raw(`"null"`)}
      | Bool => {
          serializer: unknown => {
            if unknown === %raw(`false`) {
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

let getVariantsTags = variants => {
  variants->Js.Array2.map(variant => variant->S.parseOrThrow(Schema.variantTag))
}

module Set = {
  type t<'value>

  /*
   * Constructor
   */
  @ocaml.doc("Creates a new `Set` object.") @new
  external make: unit => t<'value> = "Set"

  @ocaml.doc("Creates a new `Set` object.") @new
  external fromArray: array<'value> => t<'value> = "Set"

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

  let addMany = (set, values) => values->Js.Array2.forEach(value => set->add(value)->ignore)

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

module Map = {
  type t<'k, 'v> = Js.Map.t<'k, 'v>

  @new external make: unit => t<'k, 'v> = "Map"

  @send external get: (t<'k, 'v>, 'k) => option<'v> = "get"
  @send external unsafeGet: (t<'k, 'v>, 'k) => 'v = "get"
  @send external has: (t<'k, 'v>, 'k) => bool = "has"
  @send external set: (t<'k, 'v>, 'k, 'v) => t<'k, 'v> = "set"
  @send external delete: (t<'k, 'v>, 'k) => bool = "delete"
}

module Proxy = {
  type traps<'a> = {get?: (~target: 'a, ~prop: unknown) => unknown}

  @new
  external make: ('a, traps<'a>) => 'a = "Proxy"
}

module Hash = {
  let fail = name => {
    Js.Exn.raiseError(
      `Failed to get hash for ${name}. If you're using a custom Sury schema make it based on the string type with a decoder: const myTypeSchema = S.transform(S.string, undefined, (yourType) => yourType.toString())`,
    )
  }

  // Hash to JSON string. No specific reason for this,
  // just to stick to at least some sort of spec.
  // After Sury v11 is out we'll be able to do it with schema
  let rec makeOrThrow = (any: 'a): string => {
    switch any->Js.typeof {
    | "string" => `"${any->magic}"` // Ideally should escape here,
    // but since we don't parse it back, it's fine to keep it super simple
    | "number" => any->magic->Js.Int.toString
    | "bigint" => `"${any->magic->BigInt.toString}"`
    | "boolean" => any->magic ? "true" : "false"
    | "undefined" => "null"
    | "object" =>
      if any === %raw(`null`) {
        "null"
      } else if any->Js.Array2.isArray {
        let any: array<'a> = any->magic
        let hash = ref("[")
        for i in 0 to any->Js.Array2.length - 1 {
          if i !== 0 {
            hash := hash.contents ++ ","
          }
          hash := hash.contents ++ any->Js.Array2.unsafe_get(i)->makeOrThrow
        }
        hash.contents ++ "]"
      } else {
        let any: dict<'a> = any->magic
        let constructor = any->Js.Dict.unsafeGet("constructor")->magic
        if constructor === %raw(`Object`) {
          let hash = ref("{")
          let keys = any->Js.Dict.keys->Js.Array2.sortInPlace
          let isFirst = ref(true)
          for i in 0 to keys->Js.Array2.length - 1 {
            let key = keys->Js.Array2.unsafe_get(i)
            let value = any->Js.Dict.unsafeGet(key)
            if value !== %raw(`undefined`) {
              if isFirst.contents {
                isFirst := false
              } else {
                hash := hash.contents ++ ","
              }
              // Ideally should escape and wrap the key in double quotes
              // but since we don't need to decode the hash,
              // it's fine to keep it super simple
              hash := hash.contents ++ `"${key}":${any->Js.Dict.unsafeGet(key)->makeOrThrow}`
            }
          }
          hash.contents ++ "}"
        } else if constructor["name"] === "BigNumber" {
          `"${(any->magic)["toString"]()}"`
        } else {
          fail((constructor->magic)["name"])
        }
      }
    | "symbol"
    | "function" =>
      (any->magic)["toString"]()
    | typeof => fail(typeof)
    }
  }
}

let prettifyExn = exn => {
  switch exn->Js.Exn.anyToExnInternal {
  | Js.Exn.Error(e) => e->(magic: Js.Exn.t => exn)
  | exn => exn
  }
}
