// The worker side of a supervised run: a process the supervisor forked to drive
// a subset of the chains. It has no server and no TUI of its own — it reports
// through the IPC channel, and the supervisor is the one operational surface.

// Set by a supervisor in the environment of the workers it forks. Internal:
// it counts only together with the fork's own channel, so a copy left in a
// shell starts nothing, and an indexer a user starts themselves takes every
// path it takes today.
let envVar = "ENVIO_INTERNAL_WORKER"

let detect = (~env: dict<string>, ~hasChannel) =>
  hasChannel && env->Dict.get(envVar) === Some("true")

let isEnabled = detect(
  ~env=NodeJs.Process.process.env,
  ~hasChannel=NodeJs.Process.channel->Nullable.toOption->Option.isSome,
)

@tag("kind")
type parentMessage =
  // The config the supervisor parsed, narrowed to this worker's chains. Sent
  // instead of re-derived so a worker and its supervisor can never disagree
  // about what is being indexed.
  | @as("init") Init({config: JSON.t})
  | @as("syncCache") SyncCache({})

@tag("kind")
type workerMessage =
  | @as("snapshot") Snapshot({metrics: Metrics.t, runtime: Metrics.runtimeSample})
  // Sent once the worker's effect cache is on disk, so the supervisor's
  // console can answer for a dump that has actually happened.
  | @as("cacheSynced") CacheSynced({})

// How often a worker reports. Matches the TUI's own refresh, so the supervised
// display moves at the same rate an unsplit run's does.
let snapshotIntervalMillis = 500

// The supervisor is the one that stops a worker, and the one whose absence
// ends it. A terminal's interrupt reaches the whole group at once, so the
// worker leaves it to the supervisor, which stops every worker in turn; without
// that, a worker gone on its own would read as a failure to the supervisor
// still deciding what the interrupt meant. A supervisor that dies can't tear
// the group down, so losing the channel is what ends the worker then.
let bindToSupervisor = () => {
  NodeJs.Process.onSignal("SIGINT", () => ())
  NodeJs.Process.onDisconnect(() => {
    Logging.error("The indexer supervisor is gone. Stopping this chain's process.")
    NodeJs.process->NodeJs.exitWithCode(Failure)
  })
}

let send = (message: workerMessage) =>
  if isEnabled {
    NodeJs.Process.sendToParent(message)->ignore
  }

%%private(let pending: ref<array<parentMessage>> = ref([]))
%%private(let handler: ref<option<parentMessage => unit>> = ref(None))

// Installed before the indexer starts. A request can reach a worker while it is
// still coming up, and a dropped one leaves the supervisor waiting for an answer
// that will never be sent, so it waits for its handler instead.
let listen = () =>
  NodeJs.Process.onMessage((message: parentMessage) =>
    switch handler.contents {
    | Some(handle) => handle(message)
    | None => pending := pending.contents->Array.concat([message])
    }
  )

let onParentMessage = (handle: parentMessage => unit) => {
  handler := Some(handle)
  let held = pending.contents
  pending := []
  held->Array.forEach(handle)
}

// Resolves with the init payload. The supervisor sends it right after the
// fork, before anything else, so the first message is the only one to read.
let awaitInit = (): promise<JSON.t> =>
  Promise.make((resolve, reject) =>
    NodeJs.Process.onceMessage((message: parentMessage) =>
      switch message {
      | Init({config}) => resolve(config)
      | SyncCache(_) => reject(Utils.Error.make("Expected the supervisor's init message first"))
      }
    )
  )
