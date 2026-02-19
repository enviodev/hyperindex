@@directive("import packageJson from '../package.json' with { type: 'json' }")

external magic: 'a => 'b = "%identity"

@val external importPath: string => promise<unknown> = "import"

@val
external importPathWithJson: (
  string,
  @as(json`{with: {type: "json"}}`) _,
) => promise<{
  "default": JSON.t,

  // Check for null, since we generate S.null schema for db serializing
  // In the future it should be changed to Option only
}> = "import"

let delay = milliseconds =>
  Promise.make((resolve, _) => {
    let _interval = setTimeout(_ => {
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

  // Property descriptor with required value field (no boxing)
  type enumerablePropertyDescriptor<'a> = {
    enumerable: bool,
    value: 'a,
  }

  @val @scope("Object")
  external definePropertyWithValue: ('obj, string, enumerablePropertyDescriptor<'a>) => 'obj =
    "defineProperty"

  @val @scope("Object")
  external createNullObject: (@as(json`null`) _, unit) => 'a = "create"
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
    | None => JsError.throwWithMessage(message)
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
  /**
    It's the same as `Js.Dict.get` but it doesn't have runtime overhead to check if the key exists.
   */
  @get_index
  external dangerouslyGetNonOption: (dict<'a>, string) => option<'a> = ""

  let getOrInsertEmptyDict = (dict, key) => {
    switch dict->dangerouslyGetNonOption(key) {
    | Some(d) => d
    | None => {
        let d = Dict.make()
        dict->Dict.set(key, d)
        d
      }
    }
  }

  /**
    It's the same as `Js.Dict.get` but it doesn't have runtime overhead to check if the key exists.
   */
  @get_index
  external dangerouslyGetByIntNonOption: (dict<'a>, int) => option<'a> = ""

  let has: (dict<'a>, string) => bool = %raw(`(dict, key) => key in dict`)

  let push = (dict, key, value) => {
    switch dict->dangerouslyGetNonOption(key) {
    | Some(arr) => arr->Array.push(value)->ignore
    | None => dict->Dict.set(key, [value])
    }
  }

  let pushMany = (dict, key, values) => {
    switch dict->dangerouslyGetNonOption(key) {
    | Some(arr) => arr->Array.pushMany(values)->ignore
    | None => dict->Dict.set(key, values)
    }
  }

  let merge: (dict<'a>, dict<'a>) => dict<'a> = %raw(`(dictA, dictB) => ({...dictA, ...dictB})`)

  @val
  external mergeInPlace: (dict<'a>, dict<'a>) => dict<'a> = "Object.assign"

  // Use %raw to support for..in which is a ~10% faster than .forEach
  let mapValues: (dict<'a>, 'a => 'b) => dict<'b> = %raw(`(dict, f) => {
    var target = {}, i;
    for (i in dict) {
      target[i] = f(dict[i]);
    }
    return target;
  }`)

  // Use %raw to support for..in which is a ~10% faster than .forEach
  let filterMapValues: (dict<'a>, 'a => option<'b>) => dict<'b> = %raw(`(dict, f) => {
    var target = {}, i, v;
    for (i in dict) {
      v = f(dict[i]);
      if (v !== undefined) {
        target[i] = v;
      }
    }
    return target;
  }`)

  // Use %raw to support for..in which is a ~10% faster than .forEach
  let mapValuesToArray: (dict<'a>, 'a => 'b) => array<'b> = %raw(`(dict, f) => {
    var target = [], i;
    for (i in dict) {
      target.push(f(dict[i]));
    }
    return target;
  }`)

  // Use %raw to support for..in which is a ~10% faster than .forEach
  let forEach: (dict<'a>, 'a => unit) => unit = %raw(`(dict, f) => {
    for (var i in dict) {
      f(dict[i]);
    }
  }`)

  // Use %raw to support for..in which is a ~10% faster than .forEach
  let forEachWithKey: (dict<'a>, ('a, string) => unit) => unit = %raw(`(dict, f) => {
    for (var i in dict) {
      f(dict[i], i);
    }
  }`)

  // Use %raw to support for..in which is a ~10% faster than Object.keys
  let size: dict<'a> => int = %raw(`(dict) => {
    var size = 0, i;
    for (i in dict) {
      size++;
    }
    return size;
  }`)

  // Use %raw to support for..in which is a 2x faster than Object.keys
  let isEmpty: dict<'a> => bool = %raw(`(dict) => {
    for (var _ in dict) {
      return false
    }
    return true
  }`)

  let deleteInPlace: (dict<'a>, string) => unit = %raw(`(dict, key) => {
      delete dict[key];
    }
  `)

  let unsafeDeleteUndefinedFieldsInPlace: 'a => unit = %raw(`(dict) => {
      for (var key in dict) {
        if (dict[key] === undefined) {
          delete dict[key];
        }
      }
    }
  `)

  let updateImmutable: (
    dict<'a>,
    string,
    'a,
  ) => dict<'a> = %raw(`(dict, key, value) => ({...dict, [key]: value})`)

  let shallowCopy: dict<'a> => dict<'a> = %raw(`(dict) => ({...dict})`)

  @set_index
  external setByInt: (dict<'a>, int, 'a) => unit = ""

  let incrementByInt: (dict<int>, int) => unit = %raw(`(dict, key) => {
    dict[key]++
  }`)
}

module Math = {
  let minOptInt = (a, b) =>
    switch (a, b) {
    | (Some(a), Some(b)) => Some(a < b ? a : b)
    | (Some(a), None) => Some(a)
    | (None, Some(b)) => Some(b)
    | (None, None) => None
    }
}

// This is a microoptimization to avoid int32 safeguards
module UnsafeIntOperators = {
  external \"*": (int, int) => int = "%mulfloat"

  external \"+": (int, int) => int = "%addfloat"

  external \"-": (int, int) => int = "%subfloat"
}

type asyncIterator<'a>

module Array = {
  let immutableEmpty: array<unknown> = []

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
          if f(xs->Array.getUnsafe(i), ys->Array.getUnsafe(j)) {
            result[k] = xs->Array.getUnsafe(i)
            loop(i + 1, j, k + 1)
          } else {
            result[k] = ys->Array.getUnsafe(j)
            loop(i, j + 1, k + 1)
          }
        } else if i < Array.length(xs) {
          result[k] = xs->Array.getUnsafe(i)
          loop(i + 1, j, k + 1)
        } else if j < Array.length(ys) {
          result[k] = ys->Array.getUnsafe(j)
          loop(i, j + 1, k + 1)
        }
      }

      loop(0, 0, 0)
      result
    }
  }

  let clearInPlace: array<'a> => unit = %raw(`(arr) => {
    arr.length = 0
  }`)

  /**
  Creates a shallow copy of the array and sets the value at the given index
  */
  let setIndexImmutable = (arr: array<'a>, index: int, value: 'a): array<'a> => {
    let shallowCopy = arr->Belt.Array.copy
    shallowCopy->Array.setUnsafe(index, value)
    shallowCopy
  }

  let transposeResults = (results: array<result<'a, 'b>>): result<array<'a>, 'b> => {
    let rec loop = (index: int, output: array<'a>): result<array<'a>, 'b> => {
      if index >= Array.length(results) {
        Ok(output)
      } else {
        switch results->Array.getUnsafe(index) {
        | Ok(value) => {
            output[index] = value
            loop(index + 1, output)
          }
        | Error(_) as err => err->(magic: result<'a, 'b> => result<array<'a>, 'b>)
        }
      }
    }

    loop(0, Belt.Array.makeUninitializedUnsafe(results->Array.length))
  }

  /**
Helper to check if a value exists in an array
*/
  let includes = (arr: array<'a>, val: 'a) =>
    arr->Array.find(item => item == val)->Belt.Option.isSome

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
      let item = arr->Array.getUnsafe(i)
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
      array->Array.slice(~start=0, ~end=index)->Array.concat(array->Array.slice(~start=index + 1))
    }
  }

  let last = (arr: array<'a>): option<'a> => arr->Belt.Array.get(arr->Array.length - 1)
  let first = (arr: array<'a>): option<'a> => arr->Belt.Array.get(0)

  let lastUnsafe = (arr: array<'a>): 'a => arr->Belt.Array.getUnsafe(arr->Array.length - 1)
  let firstUnsafe = (arr: array<'a>): 'a => arr->Array.getUnsafe(0)

  let findReverseWithIndex = (arr: array<'a>, fn: 'a => bool): option<('a, int)> => {
    let rec loop = (index: int) => {
      if index < 0 {
        None
      } else {
        let item = arr->Array.getUnsafe(index)
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
    arr->Array.forEachWithIndex((v, i) => {
      interleaved->Array.push(v)->ignore
      if i < arr->Array.length - 1 {
        interleaved->Array.push(separator)->ignore
      }
    })
    interleaved
  }

  @send
  external flatten: (array<array<'a>>, @as(1) _) => array<'a> = "flat"

  @send
  external copy: array<'a> => array<'a> = "slice"

  @send external at: (array<'a>, int) => option<'a> = "at"

  /**
  Converts an async iterator to an array by iterating through all values
  */
  let fromAsyncIterator: asyncIterator<string> => promise<
    array<string>,
  > = %raw(`async (iterator) => {
    const result = [];
    for await (const item of iterator) {
      result.push(item);
    }
    return result;
  }`)
}

module String = {
  let capitalize = str => {
    str->String.slice(~start=0, ~end=1)->String.toUpperCase ++ str->String.slice(~start=1)
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

module Url = {
  /**
  Extracts the hostname from a URL string.
  Returns None if the URL doesn't have a valid http:// or https:// protocol.
  */
  let getHostFromUrl = (url: string) => {
    // Regular expression requiring protocol and capturing hostname
    // - (https?:\/\/) : Required http:// or https:// (capturing group)
    // - ([^\/?]+) : Capture hostname (one or more characters that aren't / or ?)
    // - .* : Match rest of the string
    let regex = /https?:\/\/([^\/?]+).*/
    switch RegExp.exec(regex, url) {
    | Some(result) =>
      switch RegExp.Result.matches(result)->Belt.Array.get(1) {
      | Some(Some(host)) => Some(host)
      | _ => None
      }
    | None => None
    }
  }
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
  | Error(exn) => exn->throw
  }

external queueMicrotask: (unit => unit) => unit = "queueMicrotask"

module Schema = {
  // Sury doesn't expose setName/name. We access/mutate the name field via identity cast.
  let setName = (schema: S.t<'a>, name: string): S.t<'a> => {
    (schema->S.untag->(magic: S.untagged => {..}))["name"] = name
    schema
  }
  let getName = (schema: S.t<'a>): option<string> => {
    (schema->S.untag).name
  }

  let variantTag = S.union([S.string, S.object(s => s.field("TAG", S.string))])

  // Check if a schema is nullable or optional (S.null or S.option produce unions with Null/Undefined)
  let isNullableOrOptional = (schema: S.t<unknown>) => {
    let untagged = schema->S.untag
    switch untagged.tag {
    | Null | Undefined => true
    | Union => {
        let anyOf: array<S.t<unknown>> = (untagged->(magic: S.untagged => {..}))["anyOf"]
        anyOf->Js.Array2.some(s => {
          let t = (s->S.untag).tag
          t == Null || t == Undefined
        })
      }
    | _ => false
    }
  }

  let getNonOptionalFieldNames = schema => {
    let acc = []
    switch schema->(magic: S.t<'a> => S.t<unknown>) {
    | Object({items}) =>
      items->Js.Array2.forEach(item => {
        if !isNullableOrOptional(item.schema) {
          acc->Js.Array2.push(item.location)->ignore
        }
      })
    | _ => ()
    }
    acc
  }

  let getCapitalizedFieldNames = schema => {
    switch schema->(magic: S.t<'a> => S.t<unknown>) {
    | Object({items}) => items->Js.Array2.map(item => item.location->String.capitalize)
    | _ => []
    }
  }

  // Don't use S.unknown, since it's not serializable to json
  // In a nutshell, this is completely unsafe.
  let dbDate =
    S.json
    ->(magic: S.t<JSON.t> => S.t<Date.t>)
    ->S.transform(_ => {
      serializer: date =>
        date->(magic: Date.t => Date.t)->Date.toISOString->(magic: string => Date.t),
    })

  // ClickHouse expects timestamps as numbers (milliseconds), not ISO strings
  let clickHouseDate =
    S.json
    ->(magic: S.t<JSON.t> => S.t<Date.t>)
    ->S.transform(_ => {
      serializer: date => date->(magic: Date.t => Date.t)->Date.getTime->(magic: float => Date.t),
    })

  // When trying to serialize data to Json pg type, it will fail with
  // PostgresError: column "params" is of type json but expression is of type boolean
  // If there's bool or null on the root level. It works fine as object field values.
  let coerceToJsonPgType = schema => {
    let tag = (schema->(magic: S.t<'a> => S.t<unknown>)->S.untag).tag
    switch tag {
    // This is a workaround for Fuel Bytes type
    | Unknown => schema->S.transform(_ => {serializer: _ => %raw(`"null"`)->(magic: string => 'a)})
    | Boolean =>
      schema->S.transform(_ => {
        serializer: unknown => {
          if unknown->(magic: 'a => 'b) === %raw(`false`) {
            %raw(`"false"`)
          } else if unknown->(magic: 'a => 'b) === %raw(`true`) {
            %raw(`"true"`)
          } else {
            unknown
          }
        },
      })
    | _ => schema
    }
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

  @send
  external intersection: (t<'value>, t<'value>) => t<'value> = "intersection"

  let immutableAdd: (t<'a>, 'a) => t<'a> = %raw(`(set, value) => {
    return new Set([...set, value])
  }`)

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
  type t<'k, 'v> = WeakMap.t<'k, 'v>

  @new external make: unit => t<'k, 'v> = "WeakMap"

  @send external get: (t<'k, 'v>, 'k) => option<'v> = "get"
  @send external unsafeGet: (t<'k, 'v>, 'k) => 'v = "get"
  @send external has: (t<'k, 'v>, 'k) => bool = "has"
  @send external set: (t<'k, 'v>, 'k, 'v) => t<'k, 'v> = "set"

  let memoize = (fn: 'k => 'v): ('k => 'v) => {
    let cache = make()
    key =>
      switch cache->get(key) {
      | Some(v) => v
      | None => {
          let v = fn(key)
          let _ = cache->set(key, v)
          v
        }
      }
  }
}

module Map = {
  type t<'k, 'v> = Map.t<'k, 'v>

  @new external make: unit => t<'k, 'v> = "Map"

  @send external get: (t<'k, 'v>, 'k) => option<'v> = "get"
  @send external unsafeGet: (t<'k, 'v>, 'k) => 'v = "get"
  @send external has: (Map.t<'k, 'v>, 'k) => bool = "has"
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
    JsError.throwWithMessage(
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
    | "number" => any->magic->Int.toString
    | "bigint" => {
        // Inline to avoid circular dependency with BigInt module
        let s: string = %raw(`any.toString()`)
        `"${s}"`
      }
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
  switch exn->JsExn.anyToExnInternal {
  | JsExn(e) => e->(magic: JsExn.t => exn)
  | exn => exn
  }
}

module EnvioPackage = {
  type t = {version: string}

  let value = try %raw(`packageJson`)->S.parseJsonOrThrow(
    S.schema(s => {
      version: s.matches(S.string),
    }),
  ) catch {
  | S.Error(error) =>
    JsError.throwWithMessage(`Failed to get package.json in envio package: ${error.message}`)
  }
}
