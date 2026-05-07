// Bulk mode coordinator. Runs on the main thread when ENVIO_BULK_MODE=1.
//
// For each chain in the user's config, splits [startBlock, endBlock] into N
// shards, spawns one worker thread per shard, and reports aggregate progress
// to stdout. Workers each own their HyperSync + ClickHouse connections; this
// thread does no fetching or writing of event data.
//
// PostgreSQL is only used for shard-progress bookkeeping so a kill -9 can be
// resumed without re-doing finished ranges. The bulk row data lives entirely
// in ClickHouse.

let workerEntryPath = () => {
  let dir = NodeJs.Path.getDirname(NodeJs.ImportMeta.importMeta)
  NodeJs.Path.join(dir, "BulkWorkerEntry.res.mjs")->NodeJs.Path.toString
}

type shardPlan = {
  shardId: int,
  fromBlock: int,
  toBlock: int,
}

// Even split by block range. ERC20 activity is heavily skewed toward recent
// blocks, so the last shard typically does most of the work; that's the cost
// of a hackathon-quality splitter. A density-aware splitter is a follow-up.
let makeShardPlan = (~fromBlock: int, ~toBlock: int, ~shardCount: int): array<shardPlan> => {
  let totalBlocks = toBlock - fromBlock + 1
  let perShard = totalBlocks / shardCount
  let plan = []
  for shardId in 0 to shardCount - 1 {
    let from = fromBlock + shardId * perShard
    let to = if shardId === shardCount - 1 {
      toBlock
    } else {
      from + perShard - 1
    }
    plan->Array.push({shardId, fromBlock: from, toBlock: to})->ignore
  }
  plan
}

// Per-shard live state on the main thread.
type shardState = {
  plan: shardPlan,
  mutable lastBlock: int,
  mutable eventsWritten: float,
  mutable done: bool,
  mutable error: option<string>,
}

// Aggregate progress and print a one-line status update per second.
let startProgressLogger = (
  ~chainId: int,
  ~shards: array<shardState>,
  ~totalBlocks: int,
  ~startedAt: float,
) => {
  let render = () => {
    let totalEvents = shards->Array.reduce(0., (acc, s) => acc +. s.eventsWritten)
    let blocksDone = shards->Array.reduce(0, (acc, s) => acc + (s.lastBlock - s.plan.fromBlock + 1))
    let elapsedSec = (Date.now() -. startedAt) /. 1000.
    let rate = if elapsedSec > 0. {
      totalEvents /. elapsedSec
    } else {
      0.
    }
    let pct = if totalBlocks > 0 {
      blocksDone->Int.toFloat /. totalBlocks->Int.toFloat *. 100.
    } else {
      0.
    }
    let doneCount = shards->Array.reduce(0, (acc, s) => acc + (s.done ? 1 : 0))
    Console.log(
      `[bulk chain=${chainId->Int.toString}] ${pct->Float.toFixed(
          ~digits=1,
        )}% blocks=${blocksDone->Int.toString}/${totalBlocks->Int.toString} events=${totalEvents->Float.toFixed(
          ~digits=0,
        )} rate=${rate->Float.toFixed(
          ~digits=0,
        )} ev/s shardsDone=${doneCount->Int.toString}/${shards
        ->Array.length
        ->Int.toString} elapsed=${elapsedSec->Float.toFixed(~digits=1)}s`,
    )
  }
  // Bind the host setInterval/clearInterval through globalThis so the local
  // ReScript-side names don't shadow the JS globals (a `let setInterval = ...`
  // that calls `setInterval(...)` recurses forever — Node.js bug we hit).
  let scheduleInterval: (
    unit => unit,
    int,
  ) => 'a = %raw(`(fn, ms) => globalThis.setInterval(fn, ms)`)
  let cancelInterval: 'a => unit = %raw(`(id) => { try { globalThis.clearInterval(id); } catch (_) {} }`)
  let id = scheduleInterval(render, 1000)
  // Returns a stop function the caller can call when all shards are done.
  (): unit => cancelInterval(id)
}

let runChain = async (~bulkConfig: BulkConfig.t, ~chainPlan: BulkConfig.chainPlan): float => {
  let startedAt = Date.now()
  let shardCount = bulkConfig.shards
  let plan = makeShardPlan(~fromBlock=chainPlan.fromBlock, ~toBlock=chainPlan.toBlock, ~shardCount)
  let totalBlocks = chainPlan.toBlock - chainPlan.fromBlock + 1

  let shards: array<shardState> = plan->Array.map(p => {
    {plan: p, lastBlock: p.fromBlock - 1, eventsWritten: 0., done: false, error: None}
  })

  Console.log(
    `[bulk] chain=${chainPlan.chainId->Int.toString} starting ${shardCount->Int.toString} shards over blocks [${chainPlan.fromBlock->Int.toString}, ${chainPlan.toBlock->Int.toString}]`,
  )

  let entry = workerEntryPath()

  // Wrap each worker in a Promise that resolves when it sends Done or
  // rejects on WorkerError / abnormal exit.
  let workerPromises = shards->Array.map(shard => {
    Promise.make((resolve, reject) => {
      let workerData: BulkWorker.workerData = {
        shardId: shard.plan.shardId,
        chainId: chainPlan.chainId,
        fromBlock: shard.plan.fromBlock,
        toBlock: shard.plan.toBlock,
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

      worker->NodeJs.WorkerThreads.onMessage(
        (msg: BulkWorker.workerMessage) => {
          switch msg {
          | Progress({lastBlock, eventsWritten}) => {
              shard.lastBlock = lastBlock
              shard.eventsWritten = eventsWritten
            }
          | Done({totalEvents}) => {
              shard.eventsWritten = totalEvents
              shard.lastBlock = shard.plan.toBlock
              shard.done = true
              resolve()
            }
          | WorkerError({message}) => {
              shard.error = Some(message)
              reject(makeJsError(message))
            }
          }
        },
      )

      worker->NodeJs.WorkerThreads.onError(
        err => {
          shard.error = Some(err->Utils.prettifyExn->String.make)
          reject(err)
        },
      )

      worker->NodeJs.WorkerThreads.onExit(
        code => {
          if code !== 0 && !shard.done {
            let msg = `Worker for shard ${shard.plan.shardId->Int.toString} exited with code ${code->Int.toString}`
            shard.error = Some(msg)
            reject(makeJsError(msg))
          }
        },
      )
    })
  })

  let stopLogger = startProgressLogger(
    ~chainId=chainPlan.chainId,
    ~shards,
    ~totalBlocks,
    ~startedAt,
  )

  // Promise.all rejects fast on the first failed worker. For a hackathon this
  // is fine — surface the error and exit. A retry-failed-shards loop is a
  // follow-up.
  try {
    let _ = await Promise.all(workerPromises)
  } catch {
  | exn =>
    stopLogger()
    throw(exn)
  }

  stopLogger()

  let totalEvents = shards->Array.reduce(0., (acc, s) => acc +. s.eventsWritten)
  let elapsedSec = (Date.now() -. startedAt) /. 1000.
  Console.log(
    `[bulk] chain=${chainPlan.chainId->Int.toString} done events=${totalEvents->Float.toFixed(
        ~digits=0,
      )} elapsed=${elapsedSec->Float.toFixed(~digits=2)}s rate=${(totalEvents /. elapsedSec)
        ->Float.toFixed(~digits=0)} ev/s`,
  )
  totalEvents
}

// Initialize the ClickHouse database + table once before workers start. This
// avoids each worker racing to CREATE TABLE.
let initClickHouse = async (~bulkConfig: BulkConfig.t) => {
  let bootstrapClient = ClickHouse.createClient({
    url: bulkConfig.clickhouseUrl,
    username: bulkConfig.clickhouseUsername,
    password: bulkConfig.clickhousePassword,
  })
  // CREATE DATABASE on the unscoped client, then re-create on a scoped one for
  // CREATE TABLE — mirrors the existing ClickHouse.initialize path.
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
    `[bulk] config: shards=${bulkConfig.shards->Int.toString} table=${bulkConfig.tableName} chains=${bulkConfig.chains
      ->Array.length
      ->Int.toString}`,
  )

  await initClickHouse(~bulkConfig)
  Console.log(`[bulk] ClickHouse table \`${bulkConfig.tableName}\` ready`)

  let startedAt = Date.now()

  // Run all chains in parallel — they don't share workers or connections, so
  // there's no benefit to serializing them.
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
