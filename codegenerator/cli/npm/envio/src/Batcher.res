open Belt

module Call = {
  type input
  type output
  type t = {
    input: input,
    resolve: output => unit,
    reject: exn => unit,
    mutable promise: promise<output>,
    mutable isLoading: bool,
  }
}

module Group = {
  type t<'ctx> = {
    // Unique calls by input as a key
    calls: dict<Call.t>,
    ctx: 'ctx,
    load: (array<Call.input>, ~ctx: 'ctx) => promise<unit>,
    getUnsafeInMemory: string => Call.output,
    hasInMemory: string => bool,
  }
}

type t<'ctx> = {
  // Batches of different operations by operation key
  // Can be: Load by id, load by index, effect
  groups: dict<Group.t<'ctx>>,
  mutable isCollecting: bool,
}

let make = () => {
  groups: Js.Dict.empty(),
  isCollecting: false,
}

let schedule = async batcher => {
  // For the first schedule, wait for a microtask first
  // to collect all calls before the next await
  // If the batcher is already collecting,
  // then we do nothing. The call will be automatically
  // handled when the promise below resolves
  if !batcher.isCollecting {
    batcher.isCollecting = true
    await Promise.resolve()
    batcher.isCollecting = false

    let groups = batcher.groups
    groups
    ->Js.Dict.keys
    ->Utils.Array.forEachAsync(async key => {
      let group = groups->Js.Dict.unsafeGet(key)
      let calls = group.calls

      let inputsToLoad = []
      let currentInputKeys = []
      calls
      ->Js.Dict.keys
      ->Js.Array2.forEach(inputKey => {
        let call = calls->Js.Dict.unsafeGet(inputKey)
        if !call.isLoading {
          call.isLoading = true
          currentInputKeys->Js.Array2.push(inputKey)->ignore
          if group.hasInMemory(inputKey)->not {
            inputsToLoad->Js.Array2.push(call.input)->ignore
          }
        }
      })

      if inputsToLoad->Utils.Array.isEmpty->not {
        try {
          await group.load(inputsToLoad, ~ctx=group.ctx)
        } catch {
        | exn => {
            let exn = exn->Internal.prettifyExn
            currentInputKeys->Array.forEach(inputKey => {
              let call = calls->Js.Dict.unsafeGet(inputKey)
              call.reject(exn)
            })
          }
        }
      }

      if currentInputKeys->Utils.Array.isEmpty->not {
        currentInputKeys->Js.Array2.forEach(inputKey => {
          let call = calls->Js.Dict.unsafeGet(inputKey)
          calls->Utils.Dict.deleteInPlace(inputKey)
          call.resolve(group.getUnsafeInMemory(inputKey))
        })

        // Clean up executed batch to reset
        // logger passed to the load fn
        let latestGroup = groups->Js.Dict.unsafeGet(key)
        if latestGroup.calls->Js.Dict.keys->Utils.Array.isEmpty {
          groups->Utils.Dict.deleteInPlace(key)
        }
      }
    })
  }
}

let noopHasher = input => input->(Utils.magic: 'input => string)

let operation = (batcher, ~key, ~load, ~hasher, ~group, ~hasInMemory, ~getUnsafeInMemory) => {
  if group {
    ctx => input => {
      let inputKey = hasher === noopHasher ? input->(Utils.magic: 'input => string) : hasher(input)
      let group = switch batcher.groups->Utils.Dict.dangerouslyGetNonOption(key) {
      | Some(group) => group
      | None => {
          let g: Group.t<'ctx> = {
            calls: Js.Dict.empty(),
            ctx,
            load: load->(
              Utils.magic: ((array<'input>, ~ctx: 'ctx) => promise<unit>) => (
                array<Call.input>,
                ~ctx: 'ctx,
              ) => promise<unit>
            ),
            getUnsafeInMemory: getUnsafeInMemory->(
              Utils.magic: (string => 'output) => string => Call.output
            ),
            hasInMemory: hasInMemory->(Utils.magic: (string => bool) => string => bool),
          }
          batcher.groups->Js.Dict.set(key, g)
          g
        }
      }

      switch group.calls->Utils.Dict.dangerouslyGetNonOption(inputKey) {
      | Some(c) => c.promise
      | None => {
          let promise = Promise.make((resolve, reject) => {
            let call: Call.t = {
              input: input->(Utils.magic: 'input => Call.input),
              resolve,
              reject,
              promise: %raw(`null`),
              isLoading: false,
            }
            group.calls->Js.Dict.set(inputKey, call)
          })

          // Don't use ref since it'll allocate an object to store .contents
          (group.calls->Js.Dict.unsafeGet(inputKey)).promise = promise

          let _: promise<unit> = batcher->schedule

          promise
        }
      }->(Utils.magic: promise<Call.output> => promise<'output>)
    }
  } else {
    ctx => input => {
      let inputKey = hasher === noopHasher ? input->(Utils.magic: 'input => string) : hasher(input)
      if hasInMemory(inputKey) {
        getUnsafeInMemory(inputKey)->Promise.resolve
      } else {
        load([input], ~ctx)->Promise.thenResolve(() => {
          getUnsafeInMemory(inputKey)
        })
      }
    }
  }
}
