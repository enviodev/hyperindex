// The worker side of a supervised run: a process the supervisor forked to drive
// a subset of the chains. It has no server and no TUI of its own — it reports
// through the IPC channel, and the supervisor is the one operational surface.

// Set by a supervisor in the environment of the workers it forks. Internal:
// it counts only together with the fork's own channel, so a copy left in a
// shell starts nothing, and an indexer a user starts themselves takes every
// path it takes today.
let envVar = "ENVIO_INTERNAL_WORKER"

// What the supervisor decided about this worker, handed over in the spawn
// environment rather than over the channel: it is settled before the process
// starts, and the worker needs it before it can load its own config.
type config = {
  chainIds: array<ChainId.t>,
  // The chains this worker drives may reach the head while chains in another
  // process are still backfilling, and an indexer goes realtime as a whole or
  // not at all. Cleared by the supervisor's `ReleaseRealtime`.
  holdRealtime: bool,
}

let configSchema = S.object((s): config => {
  chainIds: s.field("chainIds", S.array(ChainId.schema)),
  holdRealtime: s.fieldOr("holdRealtime", S.bool, false),
})

// Read as this module loads, which is before anything that could catch a bare
// schema error and say where it came from.
let detect = (~env: dict<string>, ~hasChannel) =>
  switch (hasChannel, env->Dict.get(envVar)) {
  | (true, Some(json)) =>
    switch json->S.parseJsonStringOrThrow(configSchema) {
    | config => Some(config)
    | exception S.Raised(error) =>
      JsError.throwWithMessage(
        `Invalid ${envVar}: ${error->S.Error.message}. It is set by an indexer supervisor for the processes it forks, and isn't meant to be set by hand.`,
      )
    }
  | _ => None
  }

let config = detect(
  ~env=NodeJs.Process.process.env,
  ~hasChannel=NodeJs.Process.channel->Nullable.toOption->Option.isSome,
)

let isEnabled = config->Option.isSome

@tag("kind")
type parentMessage =
  // Every chain in the run has reached the head, so this worker may enter the
  // reorg threshold and switch to realtime with the rest of them.
  | @as("release-realtime") ReleaseRealtime

@tag("kind")
type workerMessage =
  | @as("snapshot") Snapshot({metrics: Metrics.t, runtime: Metrics.runtimeSample})

// How often a worker reports. Matches the TUI's own refresh, so the supervised
// display moves at the same rate an unsplit run's does.
%%private(let snapshotIntervalMillis = 500)

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

%%private(let send = (message: workerMessage) => NodeJs.Process.sendToParent(message)->ignore)

// Reports this process's chains and its own runtime for as long as it runs, so
// the supervisor can merge every worker's into the one snapshot the run serves,
// and listens for the one decision the supervisor makes on the run's behalf.
// Does nothing in a process nobody forked.
let bindRun = (~getMetrics: unit => Metrics.t, ~onReleaseRealtime: unit => unit) =>
  if isEnabled {
    Metrics.startRuntimeCollectors()
    let _intervalId = setInterval(
      () => send(Snapshot({metrics: getMetrics(), runtime: Metrics.sampleRuntime()})),
      snapshotIntervalMillis,
    )
    NodeJs.Process.onMessage((message: parentMessage) =>
      switch message {
      | ReleaseRealtime => onReleaseRealtime()
      }
    )
  }
