type writeArgs = {
  batch: Batch.t,
  config: Config.t,
  inMemoryStore: InMemoryStore.t,
  isInReorgThreshold: bool,
}

type t = {
  persistence: Persistence.t,
  mutable writePromise: option<promise<result<unit, ErrorHandling.t>>>,
  mutable pendingWrite: option<writeArgs>,
  mutable writtenCheckpointId: bigint,
}

let make = (~persistence, ~initialCheckpointId) => {
  persistence,
  writePromise: None,
  pendingWrite: None,
  writtenCheckpointId: initialCheckpointId,
}

let isWriting = writer => writer.writePromise !== None
let getWrittenCheckpointId = writer => writer.writtenCheckpointId

let getLastCheckpointId = (batch: Batch.t) =>
  switch batch.checkpointIds->Utils.Array.last {
  | Some(id) => id
  | None => 0n
  }

let rec executeWrite = writer => {
  switch writer.pendingWrite {
  | None => ()
  | Some({batch, config, inMemoryStore, isInReorgThreshold}) =>
    writer.pendingWrite = None

    let logger = Logging.getLogger()
    let timeRef = Hrtime.makeTimer()

    let promise = (async () => {
      try {
        await writer.persistence->Persistence.writeBatch(
          ~batch,
          ~config,
          ~inMemoryStore,
          ~isInReorgThreshold,
        )

        let batchCheckpointId = batch->getLastCheckpointId
        if batchCheckpointId > 0n {
          writer.writtenCheckpointId = batchCheckpointId
        }

        let dbWriteDuration = timeRef->Hrtime.timeSince->Hrtime.toSecondsFloat
        logger->Logging.childTrace({
          "msg": "Background write completed",
          "write_time_elapsed": dbWriteDuration,
        })

        // After write completes, clean up the in-memory store
        inMemoryStore->InMemoryStore.cleanupAfterWrite(~writtenCheckpointId=writer.writtenCheckpointId)

        writer.writePromise = None

        // If a new write was queued during this write, start it
        executeWrite(writer)

        Ok()
      } catch {
      | Persistence.StorageError({message, reason}) =>
        writer.writePromise = None
        Error(reason->ErrorHandling.make(~msg=message, ~logger))
      | exn =>
        writer.writePromise = None
        Error(exn->ErrorHandling.make(~msg="Failed writing batch to database", ~logger))
      }
    })()

    writer.writePromise = Some(promise)
  }
}

// Queue a write. If not currently writing, starts immediately.
let startWrite = (writer, ~writeArgs) => {
  writer.pendingWrite = Some(writeArgs)
  if !isWriting(writer) {
    executeWrite(writer)
  }
}

// Await the current write and any pending writes.
// Returns the last write result.
let awaitCurrentWrite = async writer => {
  let lastResult = ref(Ok())
  let continue = ref(true)
  while continue.contents {
    switch writer.writePromise {
    | Some(promise) =>
      let result = await promise
      lastResult := result
    | None => continue := false
    }
  }
  lastResult.contents
}

// Force a synchronous write: queue it, await everything.
let forceWrite = async (writer, ~writeArgs) => {
  writer.pendingWrite = Some(writeArgs)
  switch writer.writePromise {
  | Some(promise) =>
    let _ = await promise
  | None => ()
  }
  executeWrite(writer)
  await awaitCurrentWrite(writer)
}
