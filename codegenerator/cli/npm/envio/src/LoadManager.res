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
  type t = {
    // Unique calls by input as a key
    calls: dict<Call.t>,
    load: array<Call.input> => promise<unit>,
    getUnsafeInMemory: string => Call.output,
    hasInMemory: string => bool,
  }
}

type t = {
  // Batches of different operations by operation key
  // Can be: Load by id, load by index, effect
  groups: dict<Group.t>,
  mutable isCollecting: bool,
}

let make = () => {
  groups: Js.Dict.empty(),
  isCollecting: false,
}

let schedule = async loadManager => {
  // For the first schedule, wait for a microtask first
  // to collect all calls before the next await
  // If the loadManager is already collecting,
  // then we do nothing. The call will be automatically
  // handled when the promise below resolves
  loadManager.isCollecting = true
  await Promise.resolve()
  loadManager.isCollecting = false

  let groups = loadManager.groups
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
        await group.load(inputsToLoad)
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
      // provided load function which
      // might have an outdated function context
      let latestGroup = groups->Js.Dict.unsafeGet(key)
      if latestGroup.calls->Js.Dict.keys->Utils.Array.isEmpty {
        groups->Utils.Dict.deleteInPlace(key)
      }
    }
  })
}

let noopHasher = input => input->(Utils.magic: 'input => string)

let call = (
  loadManager,
  ~input,
  ~key,
  ~load,
  ~hasher,
  /*
   Whether the call should be grouped
   with the same calls until the next microtask
   or executed immediately
 */
  ~shouldGroup,
  ~hasInMemory,
  ~getUnsafeInMemory,
) => {
  // This is a micro-optimization to avoid a function call
  let inputKey = hasher === noopHasher ? input->(Utils.magic: 'input => string) : hasher(input)

  // We group external calls by operation to:
  // 1. Reduce the IO by allowing batch requests
  // 2. By allowing parallel processing of events
  //    and make awaits run at the same time
  //
  // In the handlers it's not as important to group
  // calls, because usually we run a single handler at a time
  // So have a quick exit when an entity is already in memory
  //
  // But since we're going to parallelize handlers per chain,
  // keep the grouping logic when the data needs to be loaded
  // It has a small additional runtime cost, but might reduce IO time
  if !shouldGroup && hasInMemory(inputKey) {
    getUnsafeInMemory(inputKey)->Promise.resolve
  } else {
    let group = switch loadManager.groups->Utils.Dict.dangerouslyGetNonOption(key) {
    | Some(group) => group
    | None => {
        let g: Group.t = {
          calls: Js.Dict.empty(),
          load: load->(
            Utils.magic: (array<'input> => promise<unit>) => array<Call.input> => promise<unit>
          ),
          getUnsafeInMemory: getUnsafeInMemory->(
            Utils.magic: (string => 'output) => string => Call.output
          ),
          hasInMemory: hasInMemory->(Utils.magic: (string => bool) => string => bool),
        }
        loadManager.groups->Js.Dict.set(key, g)
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

        if !loadManager.isCollecting {
          let _: promise<unit> = loadManager->schedule
        }

        promise
      }
    }->(Utils.magic: promise<Call.output> => promise<'output>)
  }
}
