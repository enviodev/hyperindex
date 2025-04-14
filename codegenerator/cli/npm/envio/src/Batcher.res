open Belt

module Call = {
  type input
  type output
  type t = {
    input: input,
    resolve: output => unit,
    reject: exn => unit,
    mutable promise: promise<output>,
  }
}

module Batch = {
  type t = {
    // Unique calls by input as a key
    calls: dict<Call.t>,
    operation: array<Call.input> => promise<array<Call.output>>,
  }
}

type t = {
  // Batches for different operations by operation key
  // Can be: Load by id, load by index, effect
  mutable batches: dict<Batch.t>,
  mutable isScheduled: bool,
}

let make = () => {
  batches: Js.Dict.empty(),
  isScheduled: false,
}

let schedule = async batcher => {
  // Ensure that the logic runs only once until we finish executing.
  batcher.isScheduled = true

  // Use a while loop instead of a recursive function,
  // so the memory is grabaged collected between executions.
  // Although recursive function shouldn't have caused a memory leak,
  // there's still a chance for it living for a long time.
  while batcher.isScheduled {
    // Wait for a microtask here, to get all the actions registered in case when
    // running loaders in batch or using Promise.all
    // Theoretically, we could use a setTimeout, which would allow to skip awaits for
    // some context.<entitty>.get which are already in the in memory store.
    // This way we'd be able to register more actions,
    // but assuming it would not affect performance in a positive way.
    // On the other hand `await Promise.resolve()` is more predictable, easier for testing and less memory intensive.
    await Promise.resolve()

    // Start accumulating new batches
    let batches = batcher.batches
    batcher.batches = Js.Dict.empty()

    let _ = await Promise.all(
      batches
      ->Js.Dict.keys
      ->Js.Array2.map(async batchKey => {
        let batch = batches->Js.Dict.unsafeGet(batchKey)
        let calls = batch.calls->Js.Dict.values

        let reject = exn =>
          calls->Array.forEach(call => {
            call.reject(exn->Internal.prettifyExn)
          })

        try {
          let outputs = await batch.operation(calls->Js.Array2.map(c => c.input))
          if calls->Js.Array2.length !== outputs->Js.Array2.length {
            reject(
              Utils.Error.make(
                `Invalid case. Reseived ${outputs
                  ->Js.Array2.length
                  ->Js.Int.toString} responses for ${calls
                  ->Js.Array2.length
                  ->Js.Int.toString} ${batchKey} calls.`,
              ),
            )
          } else {
            calls->Js.Array2.forEachi((call, idx) => {
              let output = outputs->Js.Array2.unsafe_get(idx)
              call.resolve(output)
            })
          }
        } catch {
        | exn => reject(exn)
        }
      }),
    )

    // If there are new loaders register, schedule the next execution immediately.
    // Otherwise reset the schedule function, so it can be triggered externally again.
    if batcher.batches->Js.Dict.values->Array.length === 0 {
      batcher.isScheduled = false
    }
  }
}

let call = (batcher, ~operationKey, ~operation, ~inputKey, ~input) => {
  let batch = switch batcher.batches->Utils.Dict.dangerouslyGetNonOption(operationKey) {
  | Some(b) => b
  | None => {
      let b: Batch.t = {
        calls: Js.Dict.empty(),
        operation: operation->(
          Utils.magic: (array<'input> => promise<array<'output>>) => array<Call.input> => promise<
            array<Call.output>,
          >
        ),
      }
      batcher.batches->Js.Dict.set(operationKey, b)
      b
    }
  }

  switch batch.calls->Utils.Dict.dangerouslyGetNonOption(inputKey) {
  | Some(c) => c.promise
  | None => {
      let promise = Promise.make((resolve, reject) => {
        let call: Call.t = {
          input: input->(Utils.magic: 'input => Call.input),
          resolve,
          reject,
          promise: %raw(`null`),
        }
        batch.calls->Js.Dict.set(inputKey, call)
      })

      // Don't use ref since it'll allocate an object to store .contents
      (batch.calls->Js.Dict.unsafeGet(inputKey)).promise = promise

      if !batcher.isScheduled {
        let _: promise<unit> = batcher->schedule
      }

      promise
    }
  }->(Utils.magic: promise<Call.output> => promise<'output>)
}
