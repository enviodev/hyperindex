// The worker side of a supervised run: a process the supervisor forked to drive
// a subset of the chains. It has no server and no TUI of its own — it reports
// through the IPC channel, and the supervisor is the one operational surface.

// Set by the supervisor on the processes it forks. An indexer a user started
// themselves never has it, and takes every path it takes today.
let isEnabled = Env.isWorker

@tag("kind")
type parentMessage =
  // The config the supervisor parsed, narrowed to this worker's chains. Sent
  // instead of re-derived so a worker and its supervisor can never disagree
  // about what is being indexed.
  | @as("init") Init({config: JSON.t})
  | @as("syncCache") SyncCache({})

@tag("kind")
type workerMessage = | @as("snapshot") Snapshot({metrics: Metrics.t})

// How often a worker reports. Matches the TUI's own refresh, so the supervised
// display moves at the same rate an unsplit run's does.
let snapshotIntervalMillis = 500

// A worker with no supervisor has nobody reading its metrics and nobody to stop
// it: the supervisor could have died before it ever got to tear the group down.
// Losing the channel is that signal.
let exitWithSupervisor = () =>
  if isEnabled {
    NodeJs.Process.onDisconnect(() => {
      Logging.error("The indexer supervisor is gone. Stopping this chain's process.")
      NodeJs.process->NodeJs.exitWithCode(Failure)
    })
  }

let send = (message: workerMessage) =>
  if isEnabled {
    NodeJs.Process.sendToParent(message)->ignore
  }

let onParentMessage = (handle: parentMessage => unit) => NodeJs.Process.onMessage(handle)

// Resolves with the init payload the supervisor sends immediately after the
// fork. Nothing else can run first: the worker has no config until it lands.
let awaitInit = (): promise<JSON.t> =>
  Promise.make((resolve, _) =>
    onParentMessage(message =>
      switch message {
      | Init({config}) => resolve(config)
      | SyncCache(_) => ()
      }
    )
  )
