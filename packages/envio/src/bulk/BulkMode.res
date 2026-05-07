// Bulk mode coordinator. Runs on the main thread when ENVIO_BULK_MODE=1.
//
// Splits each chain's [startBlock, endBlock] into fixed-size chunks (default
// 50K blocks each) and dispatches them to a pool of N worker threads through
// a work-stealing queue. Workers pull the next chunk as soon as they finish
// the current one, so all N stay busy until the full range is covered. This
// avoids the dead-tail of fixed N-shard splits, where the densest shard ends
// up dominating wall time.
//
// PostgreSQL is only used for shard-progress bookkeeping (not yet wired in).
// The bulk row data lives entirely in ClickHouse.

let workerEntryPath = () => {
  let dir = NodeJs.Path.getDirname(NodeJs.ImportMeta.importMeta)
  NodeJs.Path.join(dir, "BulkWorkerEntry.res.mjs")->NodeJs.Path.toString
}

type chunk = {
  fromBlock: int,
  toBlock: int,
}

let makeChunks = (~fromBlock: int, ~toBlock: int, ~chunkSize: int): array<chunk> => {
  let chunks = []
  let cursor = ref(fromBlock)
  while cursor.contents <= toBlock {
    let to_ = Pervasives.min(cursor.contents + chunkSize - 1, toBlock)
    chunks->Array.push({fromBlock: cursor.contents, toBlock: to_})->ignore
    cursor := to_ + 1
  }
  chunks
}

// Per-worker live state on the main thread. We track the last reported
// `lifetimeEvents` separately per worker so the global total is just a sum
// over the latest reports — no double-counting on chunk boundaries.
type workerLive = {
  mutable lastBlock: int,
  mutable lifetimeEvents: float,
  mutable currentChunk: option<chunk>,
  mutable drained: bool,
}

let startProgressLogger = (
  ~chainId: int,
  ~workers: array<workerLive>,
  ~chunksTotal: int,
  ~chunksCompleted: ref<int>,
  ~startedAt: float,
) => {
  let render = () => {
    let totalEvents = workers->Array.reduce(0., (acc, w) => acc +. w.lifetimeEvents)
    let elapsedSec = (Date.now() -. startedAt) /. 1000.
    let rate = if elapsedSec > 0. {
      totalEvents /. elapsedSec
    } else {
      0.
    }
    let drainedCount = workers->Array.reduce(0, (acc, w) => acc + (w.drained ? 1 : 0))
    let activeCount = workers->Array.length - drainedCount
    Console.log(
      `[bulk chain=${chainId->Int.toString}] chunks=${chunksCompleted.contents->Int.toString}/${chunksTotal->Int.toString} events=${totalEvents->Float.toFixed(
          ~digits=0,
        )} rate=${rate->Float.toFixed(~digits=0)} ev/s active=${activeCount->Int.toString}/${workers
        ->Array.length
        ->Int.toString} elapsed=${elapsedSec->Float.toFixed(~digits=1)}s`,
    )
  }
  // Bind to the JS globals through globalThis so the local `setInterval`
  // identifier doesn't shadow itself (`let setInterval = (...) => setInterval(...)`
  // self-recurses → Maximum call stack size exceeded).
  let scheduleInterval: (
    unit => unit,
    int,
  ) => 'a = %raw(`(fn, ms) => globalThis.setInterval(fn, ms)`)
  let cancelInterval: 'a => unit = %raw(`(id) => { try { globalThis.clearInterval(id); } catch (_) {} }`)
  let id = scheduleInterval(render, 1000)
  (): unit => cancelInterval(id)
}

let runChain = async (~bulkConfig: BulkConfig.t, ~chainPlan: BulkConfig.chainPlan): float => {
  let startedAt = Date.now()
  let workerCount = bulkConfig.shards
  let chunkSize = bulkConfig.chunkSize
  let chunks = makeChunks(~fromBlock=chainPlan.fromBlock, ~toBlock=chainPlan.toBlock, ~chunkSize)
  let chunksTotal = chunks->Array.length
  let nextChunkIdx = ref(0)
  let chunksCompleted = ref(0)

  Console.log(
    `[bulk] chain=${chainPlan.chainId->Int.toString} workers=${workerCount->Int.toString} chunkSize=${chunkSize->Int.toString} chunks=${chunksTotal->Int.toString} blocks=[${chainPlan.fromBlock->Int.toString}, ${chainPlan.toBlock->Int.toString}]`,
  )

  let workers: array<workerLive> = Array.make(
    ~length=workerCount,
    {
      lastBlock: 0,
      lifetimeEvents: 0.,
      currentChunk: None,
      drained: false,
    },
  )
  // Array.make duplicates the same record reference for every slot; rebuild
  // each slot so the per-worker state is independent.
  for i in 0 to workerCount - 1 {
    workers->Array.setUnsafe(
      i,
      {lastBlock: 0, lifetimeEvents: 0., currentChunk: None, drained: false},
    )
  }

  let entry = workerEntryPath()

  let workerPromises = Belt.Array.makeBy(workerCount, workerId => {
    Promise.make((resolve, reject) => {
      let workerData: BulkWorker.workerData = {
        workerId,
        chainId: chainPlan.chainId,
        hypersyncUrl: chainPlan.hypersyncUrl,
        hypersyncToken: bulkConfig.hypersyncToken,
        contractAddresses: chainPlan.contractAddresses,
        eventSignature: chainPlan.eventSignature,
        topic0: BulkSchema.erc20Transfer.topic0,
        clickhouseUrl: bulkConfig.clickhouseUrl,
        clickhouseDatabase: bulkConfig.clickhouseDatabase,
        clickhouseUsername: bulkConfig.clickhouseUsername,
        clickhousePassword: bulkConfig.clickhousePassword,
        tableName: bulkConfig.tableName,
      }
      let worker = NodeJs.WorkerThreads.makeWorker(
        entry,
        {
          workerData: workerData->(Utils.magic: BulkWorker.workerData => JSON.t),
        },
      )

      let makeJsError: string => exn = %raw(`(s) => new Error(s)`)
      let postToWorker: (
        'a,
        BulkWorker.mainMessage,
      ) => unit = %raw(`(w, msg) => w.postMessage(msg)`)

      let dispatchOrDrain = () => {
        if nextChunkIdx.contents < chunksTotal {
          let chunk = chunks->Array.getUnsafe(nextChunkIdx.contents)
          nextChunkIdx := nextChunkIdx.contents + 1
          let workerLive = workers->Array.getUnsafe(workerId)
          workerLive.currentChunk = Some(chunk)
          worker->postToWorker(Work({fromBlock: chunk.fromBlock, toBlock: chunk.toBlock}))
        } else {
          worker->postToWorker(Drain({_dummy: false}))
        }
      }

      worker->NodeJs.WorkerThreads.onMessage(
        (msg: BulkWorker.workerMessage) => {
          switch msg {
          | Ready(_) => dispatchOrDrain()
          | NeedNext(_) =>
            chunksCompleted := chunksCompleted.contents + 1
            dispatchOrDrain()
          | Progress({workerId: wid, lastBlock, lifetimeEvents}) =>
            let w = workers->Array.getUnsafe(wid)
            w.lastBlock = lastBlock
            w.lifetimeEvents = lifetimeEvents
          | Drained({workerId: wid, totalEvents}) =>
            let w = workers->Array.getUnsafe(wid)
            w.lifetimeEvents = totalEvents
            w.drained = true
            resolve()
          | WorkerError({message}) => reject(makeJsError(message))
          }
        },
      )

      worker->NodeJs.WorkerThreads.onError(
        err => {
          reject(err)
        },
      )

      worker->NodeJs.WorkerThreads.onExit(
        code => {
          let w = workers->Array.getUnsafe(workerId)
          if code !== 0 && !w.drained {
            reject(
              makeJsError(
                `Worker ${workerId->Int.toString} exited with code ${code->Int.toString}`,
              ),
            )
          }
        },
      )
    })
  })

  let stopLogger = startProgressLogger(
    ~chainId=chainPlan.chainId,
    ~workers,
    ~chunksTotal,
    ~chunksCompleted,
    ~startedAt,
  )

  try {
    let _ = await Promise.all(workerPromises)
  } catch {
  | exn =>
    stopLogger()
    throw(exn)
  }

  stopLogger()

  let totalEvents = workers->Array.reduce(0., (acc, w) => acc +. w.lifetimeEvents)
  let elapsedSec = (Date.now() -. startedAt) /. 1000.
  Console.log(
    `[bulk] chain=${chainPlan.chainId->Int.toString} done events=${totalEvents->Float.toFixed(
        ~digits=0,
      )} elapsed=${elapsedSec->Float.toFixed(~digits=2)}s rate=${(totalEvents /. elapsedSec)
        ->Float.toFixed(~digits=0)} ev/s`,
  )
  totalEvents
}

let initClickHouse = async (~bulkConfig: BulkConfig.t) => {
  let bootstrapClient = ClickHouse.createClient({
    url: bulkConfig.clickhouseUrl,
    username: bulkConfig.clickhouseUsername,
    password: bulkConfig.clickhousePassword,
  })
  await bootstrapClient->ClickHouse.exec({
    query: `CREATE DATABASE IF NOT EXISTS \`${bulkConfig.clickhouseDatabase}\``,
  })
  await bootstrapClient->ClickHouse.close

  let scopedClient = ClickHouse.createClient({
    url: bulkConfig.clickhouseUrl,
    database: bulkConfig.clickhouseDatabase,
    username: bulkConfig.clickhouseUsername,
    password: bulkConfig.clickhousePassword,
  })
  await scopedClient->ClickHouse.exec({
    query: BulkSchema.createTableSqlForErc20Transfer(~tableName=bulkConfig.tableName),
  })
  await scopedClient->ClickHouse.close
}

let start = async (~config: Config.t) => {
  Console.log("[bulk] ENVIO_BULK_MODE detected — running write-only ClickHouse firehose")

  let bulkConfig = await BulkConfig.buildFromConfig(~config)
  Console.log(
    `[bulk] config: workers=${bulkConfig.shards->Int.toString} chunkSize=${bulkConfig.chunkSize->Int.toString} table=${bulkConfig.tableName} chains=${bulkConfig.chains
      ->Array.length
      ->Int.toString}`,
  )

  await initClickHouse(~bulkConfig)
  Console.log(`[bulk] ClickHouse table \`${bulkConfig.tableName}\` ready`)

  let startedAt = Date.now()

  let perChainTotals = await bulkConfig.chains
  ->Array.map(chainPlan => runChain(~bulkConfig, ~chainPlan))
  ->Promise.all

  let totalEvents = perChainTotals->Array.reduce(0., (a, b) => a +. b)
  let totalElapsedSec = (Date.now() -. startedAt) /. 1000.
  Console.log(
    `[bulk] all chains complete: events=${totalEvents->Float.toFixed(
        ~digits=0,
      )} elapsed=${totalElapsedSec->Float.toFixed(~digits=2)}s rate=${(totalEvents /.
      totalElapsedSec)->Float.toFixed(~digits=0)} ev/s`,
  )

  NodeJs.process->NodeJs.exitWithCode(Success)
}
