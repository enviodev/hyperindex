// One worker process and the chains it drives. `maxConnections` is its slice of
// the run's connection budget, which the pool it opens is capped to.
type worker = {chainIds: array<ChainId.t>, maxConnections: int}

// Every worker needs enough connections to read and write without serializing
// on a single one, so the budget buys workers two at a time.
let minConnectionsPerWorker = 2

// How to spend a connection budget on the chains a run indexes. `None` keeps
// the run in one process, which is what a budget too small to afford two
// workers, or a config with nothing to split, has to do.
//
// Chains are dealt in config order and the direction reverses each pass, so
// the first chains lead different workers and the worker that took the first
// picks up the last. How much work a chain has is the contracts' to decide,
// not the chain's, so config order is the one ranking the run can be given:
// listing chains busiest-first in config.yaml is what balances the layout.
let plan = (~chainIds: array<ChainId.t>, ~maxConnections: int): option<array<worker>> => {
  let workerCount = Pervasives.min(chainIds->Array.length, maxConnections / minConnectionsPerWorker)
  if workerCount < 2 {
    None
  } else {
    // The remainder is handed out one connection at a time rather than left
    // unspent, so a budget with slack widens the earliest workers' pools.
    let evenShare = maxConnections / workerCount
    let remainder = mod(maxConnections, workerCount)
    Some(
      Array.fromInitializer(~length=workerCount, workerIndex => {
        chainIds: chainIds->Array.filterWithIndex((_, dealIndex) => {
          let position = mod(dealIndex, workerCount)
          let isReversePass = mod(dealIndex / workerCount, 2) === 1
          (isReversePass ? workerCount - 1 - position : position) === workerIndex
        }),
        maxConnections: evenShare + (workerIndex < remainder ? 1 : 0),
      }),
    )
  }
}

// Whether this run splits, and how. A schema that shares entities across chains
// can't be split: workers each advance their own checkpoint sequence, which only
// holds while no entity has rows another chain can reach. A run that is already
// one chain's process doesn't split again — whoever started it owns the layout.
let planForRun = (~config: Config.t, ~maxConnections=Env.Db.maxConnections) =>
  if config.isolated || !(config->Config.isPerChain) {
    None
  } else {
    plan(~chainIds=config.chainMap->ChainMap.values->Array.map(chain => chain.id), ~maxConnections)
  }

// One forked worker: the process, the chains it drives, and the last snapshot
// it reported. `None` until it reports, which is what makes a run that hasn't
// heard from anyone yet render as initializing rather than as empty.
type running = {
  worker: worker,
  child: NodeJs.ChildProcess.child,
  mutable snapshot: option<Metrics.t>,
  mutable runtime: option<Metrics.runtimeSample>,
  // A spawn failure can raise `error` and `exit` both, and a worker counted
  // twice would end the run while its siblings are still indexing.
  mutable settled: bool,
  // Waiting for this worker's cache dump, when a console asked for one.
  mutable onCacheSynced: option<unit => unit>,
}

// A worker is named by the chains it drives, which is what an operator reading
// its memory or its event loop wants to know.
let name = (worker: worker) => worker.chainIds->Array.map(ChainId.toString)->Array.joinUnsafe(";")

let label = (worker: worker) => `[chain ${worker->name}]`

// Workers append to files of their own. Pino writes a line per call, and
// several processes appending to one file can still tear a long line apart.
let logFilePath = (~workerIndex, ~path=Env.logFilePath) => {
  let suffix = `.worker-${workerIndex->Int.toString}`
  // A dot in a directory name isn't an extension: `./logs/envio` keeps its
  // whole path and takes the suffix at the end.
  let dot = path->String.lastIndexOf(".")
  if dot > path->String.lastIndexOf("/") && dot !== -1 {
    `${path->String.slice(~start=0, ~end=dot)}${suffix}${path->String.slice(
        ~start=dot,
        ~end=path->String.length,
      )}`
  } else {
    `${path}${suffix}`
  }
}

let configForWorker = (configJson: JSON.t, ~worker) =>
  switch configJson->JSON.Decode.object {
  | Some(fields) => {
      let narrowed = fields->Dict.copy
      narrowed->Dict.set(
        "isolatedChains",
        worker.chainIds->S.reverseConvertToJsonOrThrow(S.array(ChainId.schema)),
      )
      JSON.Object(narrowed)
    }
  | None => JsError.throwWithMessage("Invalid indexer config: not an object")
  }

let fork = (
  worker: worker,
  ~workerIndex,
  ~configJson,
  // The entry this process was itself started from, so a worker is the same
  // program as its supervisor however the package was installed.
  ~entryPath=NodeJs.Process.argv->Array.getUnsafe(1),
) => {
  let env = NodeJs.Process.process.env->Dict.copy
  env->Dict.set(Worker.envVar, "true")
  // The worker's slice of the budget. Read when the worker's own Env module
  // loads, which is why it rides in the spawn environment rather than a message.
  env->Dict.set("ENVIO_PG_MAX_CONNECTIONS", worker.maxConnections->Int.toString)
  env->Dict.set("LOG_FILE", logFilePath(~workerIndex))

  let child = NodeJs.ChildProcess.fork(
    entryPath,
    [],
    {
      env,
      serialization: "advanced",
      // Workers write straight to the run's own output. Their lines already say
      // which chain they came from, so there is nothing for the supervisor to
      // add by reading them first.
      stdio: ["inherit", "inherit", "inherit", "ipc"],
    },
  )
  child
  ->NodeJs.ChildProcess.send(Worker.Init({config: configJson->configForWorker(~worker)}))
  ->ignore

  let running = {
    worker,
    child,
    snapshot: None,
    runtime: None,
    settled: false,
    onCacheSynced: None,
  }
  child->NodeJs.ChildProcess.onMessage(message =>
    switch message {
    | Worker.Snapshot({metrics, runtime}) => {
        running.snapshot = Some(metrics)
        running.runtime = Some(runtime)
      }
    | Worker.CacheSynced(_) =>
      switch running.onCacheSynced {
      | Some(resolve) =>
        running.onCacheSynced = None
        resolve()
      | None => ()
      }
    }
  )
  running
}

// The forked workers of one run, and whether their supervisor is the one
// taking them down. A stop it asked for is expected; every other way a worker
// can end is a failure.
type group = {
  running: array<running>,
  mutable stopping: bool,
  // The dump in flight, if any. A second request joins it rather than asking
  // for a dump of its own, so overlapping requests both get an answer.
  mutable syncing: option<promise<unit>>,
}

let stop = group => {
  group.stopping = true
  group.running->Array.forEach(r => r.child->NodeJs.ChildProcess.kill("SIGTERM")->ignore)
}

// Dumps every worker's effect cache. Resolves once they have all reported the
// dump done, so the console the supervisor serves can't answer for writes that
// are still in flight.
let syncCache = group =>
  switch group.syncing {
  | Some(inFlight) => inFlight
  | None =>
    let inFlight =
      group.running
      ->Array.filter(r => !r.settled)
      ->Array.map(r =>
        Promise.make((resolve, _) => {
          r.onCacheSynced = Some(() => resolve())
          r.child->NodeJs.ChildProcess.send(Worker.SyncCache({}))->ignore
        })
      )
      ->Promise.all
      ->Promise.thenResolve(_ => group.syncing = None)
    group.syncing = Some(inFlight)
    inFlight
  }

// How a group ended. `Finished` is every worker exiting cleanly on its own,
// which is what indexing to every end block looks like.
type outcome = Finished | Stopped

// Resolves once every worker has ended. Throws if any of them ended in a way
// the supervisor didn't ask for, having first taken the rest down: one worker
// short leaves its chains unindexed, and a run that kept the others going would
// look healthy while falling behind.
let awaitExit = async (group): outcome => {
  let failed = ref(false)
  let alive = ref(group.running->Array.length)

  await Promise.make((resolve, _) => {
    let onGone = (r, ~failure) =>
      if !r.settled {
        r.settled = true
        if failure {
          failed := true
          if !group.stopping {
            group->stop
          }
        }
        alive := alive.contents - 1
        if alive.contents === 0 {
          resolve()
        }
      }

    group.running->Array.forEach(r => {
      r.child->NodeJs.ChildProcess.onExit(
        (code, _signal) =>
          // Only an exit the supervisor asked for is expected. Anything else — a
          // non-zero code, or a signal like the kernel's out-of-memory kill.
          r->onGone(~failure=!group.stopping && code->Null.toOption !== Some(0)),
      )
      r.child->NodeJs.ChildProcess.onChildError(
        exn => {
          Logging.errorWithExn(exn, `${r.worker->label} failed to start`)
          r->onGone(~failure=true)
        },
      )
    })
  })

  if failed.contents {
    JsError.throwWithMessage("An indexer process exited with a failure. Stopped the others.")
  }
  group.stopping ? Stopped : Finished
}

// Runs the group: creates the schema for every chain, forks a worker per plan
// entry, and serves the run's metrics, console and display from what they
// report. Returns once every worker has exited; throws if any of them failed.
let run = async (~workers: array<worker>, ~configJson: JSON.t, ~reset) => {
  // Every chain's state has to exist before a worker resumes it: an isolated
  // run refuses to initialize, precisely so it can't create rows for its own
  // chains and leave the chains it skipped with nothing to resume.
  await Main.migrate(
    ~reset,
    ~resetCommand="envio start -r",
    ~runCommand=Some("envio start"),
    ~startBlockRetry=StartBlockResolver.UntilItAnswers,
  )

  let config = Config.load()
  let startTime = Date.make()
  let startTimeRef = Performance.now()

  Logging.info(
    `Splitting ${config.chainMap
      ->ChainMap.values
      ->Array.length
      ->Int.toString} chains across ${workers
      ->Array.length
      ->Int.toString} processes, from a budget of ${Env.Db.maxConnections->Int.toString} database connections.`,
  )

  let group = {
    running: workers->Array.mapWithIndex((worker, workerIndex) =>
      worker->fork(~workerIndex, ~configJson)
    ),
    stopping: false,
    syncing: None,
  }

  let reported = () => group.running->Array.filterMap(r => r.snapshot)
  let merge = snapshots =>
    Metrics.merge(
      snapshots,
      ~startTime,
      ~metricTime=Date.make(),
      ~elapsedSeconds=startTimeRef->Performance.secondsSince,
    )

  Main.startServer(
    // Nothing to report until a worker has: the run reads as initializing
    // rather than as an indexer with no chains.
    ~getMetrics=() =>
      switch reported() {
      | [] => None
      | snapshots => Some(snapshots->merge)
      },
    ~envioVersion=Utils.EnvioPackage.value.version,
    // Every process of the run, the supervisor included, under a `worker`
    // label: the memory and the event loop that matter are the workers' own.
    ~collectRuntime=() =>
      Metrics.renderRuntime(
        [(`worker="supervisor"`, Metrics.sampleRuntime())]->Array.concat(
          group.running->Array.filterMap(r =>
            r.runtime->Option.map(runtime => (`worker="${r.worker->name}"`, runtime))
          ),
        ),
      ),
    ~isDevelopmentMode=config.isDev,
    ~onSyncCache=() => group->syncCache,
  )

  let shouldUseTui = Main.shouldUseTui()
  if shouldUseTui {
    let _rerender = Tui.start(~config, ~getMetrics=() => reported()->merge)
  }

  // Whichever signal asks the run to stop, the supervisor is the one that
  // stops the workers: an interrupt from the terminal reaches them too, but
  // they leave it to the supervisor.
  NodeJs.Process.onSignal("SIGTERM", () => group->stop)
  NodeJs.Process.onSignal("SIGINT", () => group->stop)

  // The server and the signal handlers would keep this process up after its
  // last worker is gone, so the group's end has to end the process. A display
  // is the exception, as it is for a single process: it keeps the final state
  // on screen until the terminal closes it.
  switch await group->awaitExit {
  | Stopped => NodeJs.process->NodeJs.exitWithCode(Success)
  | Finished if !shouldUseTui =>
    Logging.info("Exiting with success")
    NodeJs.process->NodeJs.exitWithCode(Success)
  | Finished =>
    // With nothing left to stop, the stop signals end the display instead.
    // Registering a handler above took over from Node's default exit.
    NodeJs.Process.onSignal("SIGTERM", () => NodeJs.process->NodeJs.exitWithCode(Success))
    NodeJs.Process.onSignal("SIGINT", () => NodeJs.process->NodeJs.exitWithCode(Success))
  }
}
