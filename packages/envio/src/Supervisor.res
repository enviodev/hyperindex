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
// Chains go round-robin over the config's own order rather than by size: what
// balances a run is knowing how much work each chain has left, and that isn't
// known until the chains report their heights.
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
        chainIds: chainIds->Array.filterWithIndex((_, chainIndex) =>
          mod(chainIndex, workerCount) === workerIndex
        ),
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
  if config.isolated || config.userEntities->Array.some(entity => entity.crossChain) {
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
  // A spawn failure can raise `error` and `exit` both, and a worker counted
  // twice would end the run while its siblings are still indexing.
  mutable settled: bool,
}

let label = (worker: worker) =>
  `[chain ${worker.chainIds->Array.map(ChainId.toString)->Array.joinUnsafe(",")}]`

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

// Only the pretty strategy is written for a person to read, so only it takes a
// prefix. The structured strategies pass through untouched, since a line a log
// shipper has to parse must stay exactly what the worker emitted.
let shouldPrefixLogs = Env.logStrategy === Logging.ConsolePretty

// A chunk off a worker's pipe ends mid-line as often as not, so the tail is
// held back until the rest of it arrives. Returns the whole lines a chunk
// completed, each still newline-terminated so it writes through unchanged.
let makeLineSplitter = () => {
  let pending = ref("")
  chunk => {
    let lines = (pending.contents ++ chunk)->String.split("\n")
    pending := lines->Array.pop->Option.getOr("")
    lines->Array.map(line => `${line}\n`)
  }
}

let forward = (stream, ~prefix, ~write) => {
  let split = makeLineSplitter()
  stream->NodeJs.ChildProcess.setEncoding("utf8")
  stream->NodeJs.ChildProcess.onData(chunk =>
    split(chunk)->Array.forEach(line => write(`${prefix}${line}`))
  )
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
  env->Dict.set("ENVIO_WORKER", "true")
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
      stdio: ["pipe", "pipe", "pipe", "ipc"],
    },
  )
  child
  ->NodeJs.ChildProcess.send(Worker.Init({config: configJson->configForWorker(~worker)}))
  ->ignore

  let prefix = shouldPrefixLogs ? `${worker->label} ` : ""
  child
  ->NodeJs.ChildProcess.stdout
  ->Null.toOption
  ->Option.forEach(stream => stream->forward(~prefix, ~write=NodeJs.Process.writeStdout))
  child
  ->NodeJs.ChildProcess.stderr
  ->Null.toOption
  ->Option.forEach(stream => stream->forward(~prefix, ~write=NodeJs.Process.writeStderr))

  {worker, child, snapshot: None, settled: false}
}

// The forked workers of one run, and whether their supervisor is the one
// taking them down. A stop it asked for is expected; every other way a worker
// can end is a failure.
type group = {running: array<running>, mutable stopping: bool}

let stop = group => {
  group.stopping = true
  group.running->Array.forEach(r => r.child->NodeJs.ChildProcess.kill("SIGTERM")->ignore)
}

// Resolves once every worker has ended. Throws if any of them ended in a way
// the supervisor didn't ask for, having first taken the rest down: one worker
// short leaves its chains unindexed, and a run that kept the others going would
// look healthy while falling behind.
let awaitExit = async group => {
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
  }

  let reported = () => group.running->Array.filterMap(r => r.snapshot)
  let merge = snapshots =>
    Metrics.merge(
      snapshots,
      ~startTime,
      ~metricTime=Date.make(),
      ~elapsedSeconds=startTimeRef->Performance.secondsSince,
    )

  group.running->Array.forEach(r =>
    r.child->NodeJs.ChildProcess.onMessage(message =>
      switch message {
      | Worker.Snapshot({metrics}) => r.snapshot = Some(metrics)
      }
    )
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
    ~isDevelopmentMode=config.isDev,
    ~onSyncCache=() => {
      group.running->Array.forEach(r =>
        r.child->NodeJs.ChildProcess.send(Worker.SyncCache({}))->ignore
      )
      Promise.resolve()
    },
  )

  if Main.shouldUseTui() {
    let _rerender = Tui.start(~config, ~getMetrics=() => reported()->merge)
  }

  // Only the supervisor is signalled when the run is asked to stop, so it
  // passes that on. A terminal's own interrupt already reaches the whole group.
  NodeJs.Process.onSignal("SIGTERM", () => group->stop)
  NodeJs.Process.onSignal("SIGINT", () => group->stop)

  await group->awaitExit
}
