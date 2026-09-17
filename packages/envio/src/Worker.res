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
// the supervisor can merge every worker's into the one snapshot the run serves.
// Does nothing in a process nobody forked.
let startReporting = (~getMetrics: unit => Metrics.t) =>
  if isEnabled {
    Metrics.startRuntimeCollectors()
    let _intervalId = setInterval(
      () => send(Snapshot({metrics: getMetrics(), runtime: Metrics.sampleRuntime()})),
      snapshotIntervalMillis,
    )
  }

// Resolves with the init payload, the one message a supervisor sends its worker.
let awaitInit = (): promise<JSON.t> =>
  Promise.make((resolve, _) =>
    NodeJs.Process.onceMessage((message: parentMessage) =>
      switch message {
      | Init({config}) => resolve(config)
      }
    )
  )
