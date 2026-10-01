// One worker process and the chains it drives. `maxConnections` is its slice of
// the run's connection budget, which the pool it opens is capped to.
type worker = {chainIds: array<ChainId.t>, maxConnections: int}

// Every worker needs enough connections to read and write without serializing
// on a single one, so the budget buys workers two at a time.
let minConnectionsPerWorker = 2

// Most processes a run is split into, however much budget it is given. A worker
// is a whole Node process with its own heap, handler modules and source
// clients, and however many of them a run has, they share one machine. Past
// this a raised budget widens the workers' pools rather than adding workers.
let maxWorkers = 4

// How to spend a connection budget on the chains a run indexes. `None` keeps
// the run in one process.
//
// Chains are dealt in config order and the direction reverses each pass, so the
// first chains lead different workers and the worker that took the first picks
// up the last. How much work a chain has is the contracts' to decide, so config
// order is the only ranking the run can be given: listing chains busiest-first
// in config.yaml is what balances the layout.
let plan = (~chainIds: array<ChainId.t>, ~maxConnections: int): option<array<worker>> => {
  let workerCount =
    [chainIds->Array.length, maxConnections / minConnectionsPerWorker, maxWorkers]->Array.reduce(
      maxWorkers,
      Pervasives.min,
    )
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
// it reported.
type running = {
  worker: worker,
  child: NodeJs.ChildProcess.Child.t,
  mutable snapshot: option<Metrics.t>,
  mutable runtime: option<Metrics.runtimeSample>,
  // A spawn failure can raise `error` and `exit` both, and a worker counted
  // twice would end the run while its siblings are still indexing.
  mutable settled: bool,
}

let name = (worker: worker) => worker.chainIds->Array.map(ChainId.toString)->Array.joinUnsafe(";")

let label = (worker: worker) => `[chain ${worker->name}]`

// Workers append to files of their own. Pino writes a line per call, and
// several processes appending to one file can still tear a long line apart.
let logFilePath = (~workerIndex, ~path=Env.logFilePath) => {
  let suffix = `.worker-${workerIndex->Int.toString}`
  // A dot in a directory name isn't an extension, and a path with no dot at
  // all has none either: `./logs/envio` takes the suffix at the end.
  let dot = path->String.lastIndexOf(".")
  if dot > path->String.lastIndexOf("/") {
    `${path->String.slice(~start=0, ~end=dot)}${suffix}${path->String.slice(
        ~start=dot,
        ~end=path->String.length,
      )}`
  } else {
    `${path}${suffix}`
  }
}

// A pipe hands over whatever has been flushed, so a chunk boundary falls
// wherever the OS put it: the tail of a chunk is a line only once the chunk
// that ends it arrives. Reading pairs with a flush, since a process that dies
// mid-line still wrote what it managed to — which is when it matters most.
let readLines = (~onLine) => {
  let pending = ref("")
  let read = chunk => {
    let parts = (pending.contents ++ chunk)->String.split("\n")
    pending := parts->Array.pop->Option.getOr("")
    parts->Array.forEach(onLine)
  }
  let flush = () =>
    switch pending.contents {
    | "" => ()
    | line => {
        pending := ""
        onLine(line)
      }
    }
  (read, flush)
}

// Each worker's share of the run's memory budgets. Both are the whole indexer's
// rather than one process's, so workers that each took the whole of one would
// hold as many times the memory as the run happened to have workers.
let memoryBudgets = (~workerCount) =>
  [
    ("ENVIO_INDEXING_MAX_BUFFER_SIZE", CrossChainState.calculateTargetBufferSize()),
    ("ENVIO_IN_MEMORY_OBJECTS_TARGET", Env.inMemoryObjectsTarget->Float.toInt),
  ]->Array.map(((name, budget)) => (
    name,
    // A budget smaller than the run has workers still leaves each one something
    // to hold, rather than a pool it can never put anything in.
    Pervasives.max(1, budget / workerCount)->Int.toString,
  ))

// `pino-pretty` colorizes on this test, and a piped worker would fail it for a
// run the operator is watching in colour.
@val external stdoutIsTty: Nullable.t<bool> = "process.stdout.isTTY"

let fork = (
  worker: worker,
  ~workerIndex,
  // How many processes the run's budgets are being split between.
  ~workerCount,
  // Whether this worker waits for the run before going realtime. False when
  // every chain resumed already caught up: there is nothing left to wait for,
  // and a barrier nobody can open would hold the run forever.
  ~holdRealtime,
  // Which command the run was started by, which a worker's own parse of the
  // project's files can't tell it.
  ~isDev,
  // The entry this process was itself started from, so a worker is the same
  // program as its supervisor however the package was installed.
  ~entryPath=NodeJs.Process.argv->Array.getUnsafe(1),
  // A run that draws a display reads its workers' output instead of letting
  // them write to the terminal behind the frame's back.
  ~pipeOutput=false,
  ~onOutput=Console.log,
  ~onErrorOutput=Console.error,
  ~onSnapshot=() => (),
) => {
  let env = NodeJs.Process.process.env->Dict.copy
  env->Dict.set(
    Worker.envVar,
    {
      Worker.chainIds: worker.chainIds,
      holdRealtime,
      isDev,
    }->S.reverseConvertToJsonStringOrThrow(Worker.configSchema),
  )
  // The worker's slice of the budgets. Read when the worker's own Env module
  // loads, which is why they ride in the spawn environment rather than a message.
  env->Dict.set("ENVIO_PG_MAX_CONNECTIONS", worker.maxConnections->Int.toString)
  memoryBudgets(~workerCount)->Array.forEach(((name, share)) => env->Dict.set(name, share))
  env->Dict.set("LOG_FILE", logFilePath(~workerIndex))
  if pipeOutput && stdoutIsTty->Nullable.toOption->Option.getOr(false) {
    env->Dict.set("FORCE_COLOR", "1")
  }

  let child = NodeJs.ChildProcess.fork(
    entryPath,
    [],
    {
      env,
      serialization: "advanced",
      stdio: pipeOutput
        ? ["inherit", "pipe", "pipe", "ipc"]
        : ["inherit", "inherit", "inherit", "ipc"],
    },
  )
  if pipeOutput {
    // The supervisor writes a worker's lines the way it writes its own, which is
    // the only way ink can keep them out of its frame. Each stream keeps the one
    // it was written to, so a worker's errors stay on stderr for whoever is
    // redirecting it.
    [
      (child->NodeJs.ChildProcess.Child.stdout, onOutput),
      (child->NodeJs.ChildProcess.Child.stderr, onErrorOutput),
    ]->Array.forEach(((stream, onLine)) =>
      switch stream->Null.toOption {
      | Some(stream) => {
          let (read, flush) = readLines(~onLine)
          stream->NodeJs.ChildProcess.Stream.setEncoding("utf8")
          stream->NodeJs.ChildProcess.Stream.onData(read)
          stream->NodeJs.ChildProcess.Stream.onEnd(flush)
        }
      | None => ()
      }
    )
  }
  let running = {worker, child, snapshot: None, runtime: None, settled: false}
  child->NodeJs.ChildProcess.Child.onMessage(message =>
    switch message {
    | Worker.Snapshot({metrics, runtime}) => {
        running.snapshot = Some(metrics)
        running.runtime = Some(runtime)
        onSnapshot()
      }
    }
  )
  running
}

// The forked workers of one run, and whether their supervisor is the one
// taking them down, which is what tells an expected exit from the rest.
type group = {
  // Assigned once the forks are made, which is after the group exists: a
  // worker's report asks the group whether the run may go realtime.
  mutable running: array<running>,
  mutable stopping: bool,
  // Whether the workers are still waiting for the run's leave to go realtime.
  mutable holdingRealtime: bool,
}

let stop = group => {
  group.stopping = true
  group.running->Array.forEach(r => r.child->NodeJs.ChildProcess.Child.kill("SIGTERM")->ignore)
}

// The dev console's cache dump belongs to the supervisor: a dump copies every
// effect cache table in the schema, so a worker asked to do it would copy its
// siblings' chains too, and several asked at once would write the same files at
// the same time. Overlapping requests join the dump in flight for that reason.
let syncCache = {
  let inFlight = ref(None)
  (~dump) =>
    switch inFlight.contents {
    | Some(dumping) => dumping
    | None =>
      let dumping = dump()->Promise.finally(() => inFlight := None)
      inFlight := Some(dumping)
      dumping
    }
}

// The supervisor handed its connections to the workers, so a dump opens one of
// its own and puts the run one connection over its budget — deliberately: only
// `envio dev` asks for a dump, and the alternative is pausing the indexing to
// free one.
let dumpCache = (~config) => {
  let storage = PgStorage.makeStorageFromEnv(~config, ~sql=PgStorage.makeClient(~maxConnections=1))
  storage.dumpEffectCache()->Promise.finally(() => storage.close()->Promise.ignore)
}

// How a group ended. `Finished` is every worker exiting cleanly on its own,
// which is what indexing to every end block looks like.
type outcome = Finished | Stopped

// How one worker's ending reads.
type ending =
  // On its own terms, or because the supervisor asked.
  | Expected
  // Asked to stop by someone other than the supervisor. A process manager that
  // signals a whole group reaches the workers itself, so a worker can be told
  // before the supervisor has decided what the signal meant.
  | Stopping
  | Failed

// A worker that stops on a signal is being stopped, not failing: `systemctl
// stop` on a unit with the default `KillMode=control-group` sends SIGTERM to
// every process in it, so the workers get it directly and exit on it. Reading
// that as a failure would fail every clean shutdown under systemd.
//
// The kernel's out-of-memory killer sends SIGKILL, which stays a failure — as
// does every non-zero exit of a worker the supervisor didn't ask to stop.
//
// Once the supervisor is stopping, though, every exit reads as expected and the
// run exits 0: a worker that crashes on its way down is indistinguishable from
// one that took the SIGTERM, and a stop that reported a failure would fail
// every restart the crash happened to race.
let classifyExit = (~code: Null.t<int>, ~signal: Null.t<string>, ~stopping) =>
  switch (stopping, code->Null.toOption, signal->Null.toOption) {
  | (true, _, _)
  | (_, Some(0), _) =>
    Expected
  | (_, _, Some("SIGTERM")) => Stopping
  | _ => Failed
  }

// Resolves once every worker has ended. Throws if any of them ended in a way
// the supervisor didn't ask for, having first taken the rest down: one worker
// short leaves its chains unindexed, and a run that kept the others going would
// look healthy while falling behind.
let awaitExit = async (group): outcome => {
  let failed = ref(false)
  let alive = ref(group.running->Array.length)

  await Promise.make((resolve, _) => {
    let onGone = (r, ~ending) =>
      if !r.settled {
        r.settled = true
        // The rest of the run goes down either way; what differs is whether the
        // run reports itself as having failed.
        switch ending {
        | Expected => ()
        | Stopping => group->stop
        | Failed => {
            failed := true
            group->stop
          }
        }
        alive := alive.contents - 1
        if alive.contents === 0 {
          resolve()
        }
      }

    group.running->Array.forEach(r => {
      r.child->NodeJs.ChildProcess.Child.onExit(
        (code, signal) => r->onGone(~ending=classifyExit(~code, ~signal, ~stopping=group.stopping)),
      )
      r.child->NodeJs.ChildProcess.Child.onError(
        exn => {
          Logging.errorWithExn(exn, `${r.worker->label} failed to start`)
          r->onGone(~ending=Failed)
        },
      )
    })
  })

  if failed.contents {
    JsError.throwWithMessage("An indexer process exited with a failure. Stopped the others.")
  }
  group.stopping ? Stopped : Finished
}

// Whether a run holding its workers back may let them go: every worker is still
// there to be released, has reported, and has got as far as it can on its own.
//
// A worker that is gone leaves the run a process short, so there is nothing to
// release it into, and its last snapshot outlives it. The channel is what says
// so: Node closes it before it reports the exit, so a process on its way out
// still reads as running everywhere else, and the release sent to it comes back
// as the error a supervisor reports as a worker failing to start.
let isRunAtHead = (running: array<running>) =>
  running->Utils.Array.notEmpty &&
    running->Array.every(r =>
      r.child->NodeJs.ChildProcess.Child.connected &&
        r.snapshot->Option.mapOr(false, snapshot => snapshot.hasArrivedAtHead)
    )

// Holds every worker at the head until the last of them arrives, then releases
// them together. Chains enter the reorg threshold and go realtime as one
// indexer, and in a split run only the supervisor can see when that is.
//
// Asked on every report rather than on a clock of its own: a report is the only
// thing that can change the answer.
let releaseIfAtHead = group =>
  if group.holdingRealtime && !group.stopping && group.running->isRunAtHead {
    group.holdingRealtime = false
    group.running->Array.forEach(r =>
      r.child->NodeJs.ChildProcess.Child.send(Worker.ReleaseRealtime)->ignore
    )
  }

// The run's chains as an unsplit indexer reports them before it has fetched
// anything: at their configured blocks, with nothing indexed. A display that
// hasn't heard from a worker yet draws these, rather than the indexer with no
// chains at all that an empty merge would render.
let configuredChains = (config: Config.t): array<Metrics.chainMetrics> =>
  config.chainMap
  ->ChainMap.values
  ->Array.map((chain): Metrics.chainMetrics => {
    chainId: chain.id,
    poweredByHyperSync: switch chain.sourceConfig {
    | EvmSourceConfig({hypersync}) => hypersync->Option.isSome
    | FuelSourceConfig(_) | SvmSourceConfig(_) => true
    | SimulateSourceConfig(_) | CustomSources(_) => false
    },
    firstEventBlockNumber: None,
    latestProcessedBlock: None,
    timestampCaughtUpToHeadOrEndblock: None,
    numEventsProcessed: 0.,
    latestFetchedBlockNumber: 0,
    knownHeight: 0,
    numBatchesFetched: 0,
    // A chain resolves `start_block: latest` against its own head as it starts,
    // which is a worker's to do and no supervisor's to guess.
    startBlock: switch chain.startBlock {
    | Block(block) => block
    | Latest => 0
    },
    endBlock: chain.endBlock,
    numAddresses: 0,
    addressesByContract: [],
    isReady: false,
    sourceBlockNumber: 0,
    progressBlockNumber: -1,
    progressLatencyMs: None,
    progressBlockTime: None,
    concurrency: 0,
    partitionsCount: 0,
    bufferSize: 0,
    bufferBlockNumber: -1,
    idleSeconds: 0.,
    waitingForNewBlockSeconds: 0.,
    queryingSeconds: 0.,
    blockRangeFetchSeconds: 0.,
    blockRangeParseSeconds: 0.,
    blockRangeFetchCount: 0.,
    blockRangeFetchedEvents: 0.,
    blockRangeFetchedBlocks: 0.,
    reorgCount: 0,
    reorgDetectedBlock: None,
    rollbackTargetBlock: None,
    rateLimitTimeMs: 0.,
    rateLimitResetInMs: None,
  })

// Runs the group: creates the schema for every chain, forks a worker per plan
// entry, and serves the run's metrics, console and display from what they
// report. Returns once every worker has exited; throws if any of them failed.
let run = async (~config: Config.t, ~workers: array<worker>, ~reset) => {
  // Every chain's state has to exist before a worker resumes it: an isolated
  // run refuses to initialize, precisely so it can't create rows for its own
  // chains and leave the chains it skipped with nothing to resume. It is the
  // same initialization an unsplit run does, and the supervisor hands the
  // connections it used to its workers.
  let persistence = PgStorage.makePersistenceFromConfig(~config)
  await persistence->Persistence.initForRun(
    ~config,
    ~reset,
    ~isDevelopmentMode=config.isDev,
    ~requireInitialized=false,
  )
  await persistence.storage.close()

  let startTime = Date.make()
  let startTimeRef = Performance.now()

  // The counts ride as fields rather than in the sentence: the connection limit
  // is the only setting that decides any of this, and a reader who wants to
  // change it has nothing else to go on.
  Logging.info({
    "msg": "Indexing will be split across multiple processes for faster and more reliable indexing.",
    "chains": config.chainMap->ChainMap.values->Array.length,
    "processes": workers->Array.length,
    "maxConnections": Env.Db.maxConnections,
  })

  // Decided before the first fork: it is what makes a worker's output the
  // supervisor's to print.
  let shouldUseTui = Tui.shouldUse()
  // A run that resumed with every chain already caught up owes nobody a wait:
  // its workers start realtime and there is no barrier to open.
  let holdRealtime =
    (persistence->Persistence.getInitializedState).chains->Array.some(chain =>
      chain.timestampCaughtUpToHeadOrEndblock->Option.isNone
    )
  let group = {running: [], stopping: false, holdingRealtime: holdRealtime}
  group.running =
    workers->Array.mapWithIndex((worker, workerIndex) =>
      worker->fork(
        ~workerIndex,
        ~workerCount=workers->Array.length,
        ~holdRealtime,
        ~isDev=config.isDev,
        ~pipeOutput=shouldUseTui,
        ~onSnapshot=() => group->releaseIfAtHead,
      )
    )

  let reported = () => group.running->Array.filterMap(r => r.snapshot)
  let merge = snapshots =>
    Metrics.merge(
      snapshots,
      ~startTime,
      ~metricTime=Date.make(),
      ~elapsedSeconds=startTimeRef->Performance.secondsSince,
      // The run's pool, which its workers hold a share of each. Reporting the
      // shares added back up would say the same thing less directly, and say
      // nothing at all before every worker has reported.
      ~targetBufferSize=CrossChainState.calculateTargetBufferSize(),
    )

  Server.startServer(
    // Nothing to report until a worker has: the run reads as initializing
    // rather than as an indexer with no chains.
    ~getMetrics=() =>
      switch reported() {
      | [] => None
      | snapshots => Some(snapshots->merge)
      },
    ~envioVersion=Utils.EnvioPackage.value.version,
    // The workers' readings, each under a `worker` label: theirs are the memory
    // and the event loop the indexing runs on.
    ~collectRuntime=() =>
      Metrics.renderRuntime(
        group.running->Array.filterMap(r =>
          r.runtime->Option.map(runtime => (`worker="${r.worker->name}"`, runtime))
        ),
      ),
    ~isDevelopmentMode=config.isDev,
    ~onSyncCache=() => syncCache(~dump=() => dumpCache(~config)),
  )

  if shouldUseTui {
    let _rerender = Tui.start(~config, ~getMetrics=() =>
      switch reported() {
      | [] => {...[]->merge, chains: configuredChains(config)}
      | snapshots => snapshots->merge
      }
    )
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
  let outcome = await group->awaitExit

  switch outcome {
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
