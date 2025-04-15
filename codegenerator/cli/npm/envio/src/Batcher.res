open Belt

module Call = {
  type input
  type output
  type t = {
    input: input,
    resolve: output => unit,
    reject: exn => unit,
    mutable promise: promise<output>,
    mutable isPending: bool,
  }
}

module Operation = {
  type t = {
    // Unique calls by input as a key
    calls: dict<Call.t>,
    fn: array<Call.input> => promise<array<Call.output>>,
  }
}

type t = {
  // Batches of different operations by operation key
  // Can be: Load by id, load by index, effect
  operations: dict<Operation.t>,
  mutable isCollecting: bool,
}

let make = () => {
  operations: Js.Dict.empty(),
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

    let operations = batcher.operations
    operations
    ->Js.Dict.keys
    ->Utils.Array.forEachAsync(async operationKey => {
      let batch = operations->Js.Dict.unsafeGet(operationKey)
      let calls = batch.calls

      let inputs = []
      let inputKeys =
        calls
        ->Js.Dict.keys
        ->Js.Array2.filter(inputKey => {
          let call = calls->Js.Dict.unsafeGet(inputKey)
          if call.isPending {
            false
          } else {
            call.isPending = true
            inputs->Js.Array2.push(call.input)->ignore
            true
          }
        })

      if inputs->Utils.Array.isEmpty->not {
        let reject = exn => {
          let exn = exn->Internal.prettifyExn
          inputKeys->Array.forEach(inputKey => {
            let call = calls->Js.Dict.unsafeGet(inputKey)
            call.reject(exn)
          })
        }

        try {
          let outputs = await batch.fn(inputs)
          if inputs->Js.Array2.length !== outputs->Js.Array2.length {
            reject(
              Utils.Error.make(
                `Invalid case. Reseived ${outputs
                  ->Js.Array2.length
                  ->Js.Int.toString} responses for ${inputs
                  ->Js.Array2.length
                  ->Js.Int.toString} ${operationKey} calls.`,
              ),
            )
          } else {
            inputKeys->Js.Array2.forEachi((inputKey, idx) => {
              let call = calls->Js.Dict.unsafeGet(inputKey)
              let output = outputs->Js.Array2.unsafe_get(idx)
              calls->Utils.Dict.deleteInPlace(inputKey)
              call.resolve(output)
            })

            // Clean up executed batch to reset
            // logger passed to operation
            let latestBatch = operations->Js.Dict.unsafeGet(operationKey)
            if latestBatch.calls->Js.Dict.keys->Utils.Array.isEmpty {
              operations->Utils.Dict.deleteInPlace(operationKey)
            }
          }
        } catch {
        | exn => reject(exn)
        }
      }
    })
  }
}

let call = (batcher, ~operationKey, ~operation, ~inputKey, ~input) => {
  let o = switch batcher.operations->Utils.Dict.dangerouslyGetNonOption(operationKey) {
  | Some(o) => o
  | None => {
      let o: Operation.t = {
        calls: Js.Dict.empty(),
        fn: operation->(
          Utils.magic: (array<'input> => promise<array<'output>>) => array<Call.input> => promise<
            array<Call.output>,
          >
        ),
      }
      batcher.operations->Js.Dict.set(operationKey, o)
      o
    }
  }

  switch o.calls->Utils.Dict.dangerouslyGetNonOption(inputKey) {
  | Some(c) => c.promise
  | None => {
      let promise = Promise.make((resolve, reject) => {
        let call: Call.t = {
          input: input->(Utils.magic: 'input => Call.input),
          resolve,
          reject,
          promise: %raw(`null`),
          isPending: false,
        }
        o.calls->Js.Dict.set(inputKey, call)
      })

      // Don't use ref since it'll allocate an object to store .contents
      (o.calls->Js.Dict.unsafeGet(inputKey)).promise = promise

      let _: promise<unit> = batcher->schedule

      promise
    }
  }->(Utils.magic: promise<Call.output> => promise<'output>)
}
