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
  results->Belt.Array.reduce(Ok([]), (accum, nextItem) => {
    accum->Belt.Result.flatMap(currentOkItems => {
      nextItem->Belt.Result.map(item => Belt.Array.concat(currentOkItems, [item]))
    })
  })
}

let optionMapNone = (opt: option<'a>, val: 'b): option<'b> => {
  switch opt {
  | None => Some(val)
  | Some(_) => None
  }
}

module Tuple = {
  /**Access a tuple value by its index*/
  @warning("-27")
  let get = (tuple: 'a, index: int): option<'b> => %raw(`tuple[index]`)
}

/**
Used for an ordered key value insert, where only unique values by
key are added and they can be iterated over in the same insertion
order.
*/
module UniqueArray = {
  type keyHasher<'key> = 'key => string

  type t_custom<'key, 'val> = {
    dict: Js.Dict.t<'val>,
    idArr: Js.Array2.t<'val>,
    keyHasher: keyHasher<'key>,
  }

  type t<'val> = t_custom<string, 'val>

  let emptyCustom = (~keyHasher: keyHasher<'key>): t_custom<'key, 'val> => {
    dict: Js.Dict.empty(),
    idArr: [],
    keyHasher,
  }
  let empty = (): t<'val> => emptyCustom(~keyHasher=Obj.magic)

  let push = (self: t_custom<'key, 'val>, key: 'key, val: 'val) => {
    let id = key->self.keyHasher
    if self.dict->Js.Dict.get(id)->Belt.Option.isNone {
      self.dict->Js.Dict.set(id, val)
      self.idArr->Js.Array2.push(id)->ignore
    }
  }

  let getIndex = (self: t_custom<'key, 'val>, index: int): option<'val> => {
    self.idArr->Belt.Array.get(index)->Belt.Option.flatMap(id => self.dict->Js.Dict.get(id))
  }

  let getKey = (self: t_custom<'key, 'val>, key: 'key) => {
    let id = key->self.keyHasher
    self.dict->Js.Dict.get(id)
  }

  let forEach = (self: t_custom<'key, 'val>, fn: 'val => unit): unit => {
    self.idArr->Belt.Array.forEach(id => {
      let optVal = self.dict->Js.Dict.get(id)
      switch optVal {
      | Some(val) => val->fn
      | None => () // unexpected
      }
    })
    ()
  }

  let map = (self: t_custom<'key, 'val>, fn: 'val => 'valB): t_custom<'key, 'valB> => {
    let newSelf = emptyCustom(~keyHasher=self.keyHasher)
    self.idArr->Belt.Array.forEach(id => {
      let optVal = self.dict->Js.Dict.get(id)
      switch optVal {
      | Some(val) => {
          let mapped = val->fn
          newSelf.dict->Js.Dict.set(id, mapped)
          newSelf.idArr->Js.Array2.push(id)->ignore
        }
      | None => () // unexpected
      }
    })
    newSelf
  }

  let values = (self: t_custom<'key, 'val>): array<'val> => {
    let arr = []
    self.idArr->Belt.Array.forEach(id => {
      let optVal = self.dict->Js.Dict.get(id)
      switch optVal {
      | Some(val) => arr->Js.Array2.push(val)->ignore
      | None => () // unexpected
      }
    })
    arr
  }

  let extend = (self: t_custom<'key, 'val>, key: 'key, val: 'val): t_custom<'key, 'val> => {
    let id = key->self.keyHasher
    if self.dict->Js.Dict.get(id)->Belt.Option.isNone {
      let dictEntries = self.dict->Js.Dict.entries
      dictEntries->Js.Array2.push((id, val))->ignore
      let newDict = dictEntries->Js.Dict.fromArray
      let newIdArr = self.idArr->Belt.Array.concat([id])

      {
        ...self,
        dict: newDict,
        idArr: newIdArr,
      }
    } else {
      self
    }
  }
}
