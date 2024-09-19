module Data = {
  let dateTimeSchema = S.string->S.datetime
  module BlockRangeFetched = {
    type t = {
      stats: ChainWorker.blockRangeFetchStats,
      chainId: int,
      fromBlock: int,
      toBlock: int,
      fetchStateRegisterId: FetchState.id,
      partitionId: int,
      numEvents: int,
    }

    let make = (
      ~stats,
      ~chainId,
      ~fromBlock,
      ~toBlock,
      ~fetchStateRegisterId,
      ~partitionId,
      ~numEvents,
    ) => {
      stats,
      chainId,
      fromBlock,
      toBlock,
      fetchStateRegisterId,
      partitionId,
      numEvents,
    }

    let schema = S.object(s => {
      stats: s.field("stats", ChainWorker.blockRangeFetchStatsSchema),
      chainId: s.field("chainId", S.int),
      fromBlock: s.field("fromBlock", S.int),
      toBlock: s.field("toBlock", S.int),
      fetchStateRegisterId: s.field("fetchStateRegisterId", FetchState.idSchema),
      partitionId: s.field("partitionId", S.int),
      numEvents: s.field("numEvents", S.int),
    })
  }

  module EventProcessing = {
    type t = {
      batchSize: int,
      contractRegisterDuration: int,
      loadDuration: int,
      handlerDuration: int,
      dbWriteDuration: int,
      totalTimeElapsed: int,
      timeFinished: Js.Date.t,
    }

    let schema = S.object(s => {
      batchSize: s.field("batchSize", S.int),
      contractRegisterDuration: s.field("contractRegisterDuration", S.int),
      loadDuration: s.field("loadDuration", S.int),
      handlerDuration: s.field("handlerDuration", S.int),
      dbWriteDuration: s.field("dbWriteDuration", S.int),
      totalTimeElapsed: s.field("totalTimeElapsed", S.int),
      timeFinished: s.field("timeFinished", dateTimeSchema),
    })
  }

  type t = {
    blockRangeFetched: array<BlockRangeFetched.t>,
    eventProcessing: array<EventProcessing.t>,
    startTime: Js.Date.t,
    mutable latestTime: Js.Date.t,
  }
  let schema = S.object(s => {
    blockRangeFetched: s.field("blockRangeFetched", S.array(BlockRangeFetched.schema)),
    eventProcessing: s.field("eventProcessing", S.array(EventProcessing.schema)),
    startTime: s.field("startTime", dateTimeSchema),
    latestTime: s.field("latestTime", dateTimeSchema),
  })

  let make = () => {
    blockRangeFetched: [],
    eventProcessing: [],
    startTime: Js.Date.make(),
    latestTime: Js.Date.make(),
  }

  let addBlockRangeFetched = (self, blockRangeFetched: BlockRangeFetched.t) => {
    self.blockRangeFetched->Js.Array2.push(blockRangeFetched)->ignore
    self.latestTime = Js.Date.make()
  }

  let addEventProcessing = (self, eventProcessing: EventProcessing.t) => {
    self.eventProcessing->Js.Array2.push(eventProcessing)->ignore
    self.latestTime = Js.Date.make()
  }
}

let data = Data.make()
let cacheFileName = "BenchmarkCache.json"
let cacheFilePath = NodeJsLocal.Path.join(NodeJsLocal.Path.__dirname, cacheFileName)

let saveToCacheFile = data => {
  let json = data->S.serializeToJsonStringOrRaiseWith(Data.schema)
  NodeJsLocal.Fs.Promises.writeFile(~filepath=cacheFilePath, ~content=json)->ignore
}

let readFromCacheFile = async () => {
  switch await NodeJsLocal.Fs.Promises.readFile(~filepath=cacheFilePath, ~encoding=Utf8) {
  | exception _ => None
  | content =>
    switch content->S.parseJsonStringWith(Data.schema) {
    | Ok(data) => Some(data)
    | Error(e) =>
      Logging.error(
        "Failed to parse benchmark cache file, please delete it and rerun the benchmark",
      )
      e->S.Error.raise
    }
  }
}

let addBlockRangeFetched = (
  ~stats,
  ~chainId,
  ~fromBlock,
  ~toBlock,
  ~fetchStateRegisterId,
  ~partitionId,
  ~numEvents,
) => {
  data->Data.addBlockRangeFetched(
    Data.BlockRangeFetched.make(
      ~stats,
      ~chainId,
      ~fromBlock,
      ~toBlock,
      ~fetchStateRegisterId,
      ~partitionId,
      ~numEvents,
    ),
  )

  data->saveToCacheFile
}

let addEventProcessing = (
  ~batchSize,
  ~contractRegisterDuration,
  ~loadDuration,
  ~handlerDuration,
  ~dbWriteDuration,
  ~totalTimeElapsed,
  ~timeFinished,
) => {
  data->Data.addEventProcessing({
    batchSize,
    contractRegisterDuration,
    loadDuration,
    handlerDuration,
    dbWriteDuration,
    totalTimeElapsed,
    timeFinished,
  })

  data->saveToCacheFile
}

module Summary = {
  open Belt
  type t = {
    n: int,
    mean: float,
    @as("std-dev") stdDev: float,
    min: float,
    max: float,
  }

  type summaryTable = dict<t>

  external logSummaryTable: summaryTable => unit = "console.table"
  external logArrTable: array<'a> => unit = "console.table"
  external logObjTable: {..} => unit = "console.table"
  external logDictTable: dict<'a> => unit = "console.table"

  external arrayIntToFloat: array<int> => array<float> = "%identity"

  let round = (float, ~precision=2) => {
    let factor = Js.Math.pow_float(~base=10.0, ~exp=precision->Int.toFloat)
    Js.Math.round(float *. factor) /. factor
  }

  let make = (arr: array<float>) => {
    let div = (floatA, floatB) => floatA /. floatB
    let n = Array.length(arr)
    if n == 0 {
      {n, mean: 0., stdDev: 0., min: 0., max: 0.}
    } else {
      let nFloat = n->Int.toFloat
      let mean = arr->Array.reduce(0., (acc, time) => acc +. time)->div(nFloat)->round(~precision=2)
      let stdDev = {
        let variance =
          arr
          ->Array.reduce(0., (acc, val) => {
            let diff = val -. mean
            acc +. Js.Math.pow_float(~base=diff, ~exp=2.)
          })
          ->div(nFloat)

        variance->Js.Math.sqrt->round(~precision=2)
      }

      let min =
        arr
        ->Array.reduce(None, (acc, val) =>
          switch acc {
          | None => val
          | Some(acc) => Pervasives.min(acc, val)
          }
          ->round(~precision=2)
          ->Some
        )
        ->Option.getWithDefault(0.)
      let max =
        arr
        ->Array.reduce(None, (acc, val) =>
          switch acc {
          | None => val
          | Some(acc) => Pervasives.max(acc, val)
          }
          ->round(~precision=2)
          ->Some
        )
        ->Option.getWithDefault(0.)
      {n, mean, stdDev, min, max}
    }
  }

  let getChainBlockRangeFetchedSummary = (data: Data.t, ~chainId): summaryTable => {
    let numBlocksFetchedSamples = []
    let blockRangeSizeSamples = []
    let totalTimeElapsedSamples = []
    let parsingTimeElapsedSamples = []
    let pageFetchTimeSamples = []

    data.blockRangeFetched->Array.forEach(blockRangeFetched =>
      if blockRangeFetched.chainId == chainId {
        numBlocksFetchedSamples->Array.push(blockRangeFetched.numEvents->Int.toFloat)
        blockRangeSizeSamples->Array.push(
          Int.toFloat(blockRangeFetched.toBlock - blockRangeFetched.fromBlock),
        )
        totalTimeElapsedSamples->Array.push(blockRangeFetched.stats.totalTimeElapsed->Int.toFloat)
        parsingTimeElapsedSamples->Array.push(
          blockRangeFetched.stats.parsingTimeElapsed->Option.mapWithDefault(0., Int.toFloat),
        )
        pageFetchTimeSamples->Array.push(
          blockRangeFetched.stats.pageFetchTime->Option.mapWithDefault(0., Int.toFloat),
        )
      }
    )
    [
      ("Total Time Elapsed (ms)", totalTimeElapsedSamples->make),
      ("Parsing Time Elapsed (ms)", parsingTimeElapsedSamples->make),
      ("Page Fetch Time (ms)", pageFetchTimeSamples->make),
      ("Num Blocks Fetched", numBlocksFetchedSamples->make),
      ("Block Range Size", blockRangeSizeSamples->make),
    ]->Js.Dict.fromArray
  }
  let getEventProcessingSummary = (data: Data.t): summaryTable => {
    let batchSizeSamples = []
    let contractRegisterDurationSamples = []
    let loadDurationSamples = []
    let handlerDurationSamples = []
    let dbWriteDurationSamples = []
    let totalTimeElapsedSamples = []

    data.eventProcessing->Array.forEach(eventProcessing => {
      batchSizeSamples->Array.push(eventProcessing.batchSize->Int.toFloat)
      contractRegisterDurationSamples->Array.push(
        eventProcessing.contractRegisterDuration->Int.toFloat,
      )
      loadDurationSamples->Array.push(eventProcessing.loadDuration->Int.toFloat)
      handlerDurationSamples->Array.push(eventProcessing.handlerDuration->Int.toFloat)
      dbWriteDurationSamples->Array.push(eventProcessing.dbWriteDuration->Int.toFloat)
      totalTimeElapsedSamples->Array.push(eventProcessing.totalTimeElapsed->Int.toFloat)
    })

    [
      ("Batch Size", batchSizeSamples->make),
      ("Contract Register Duration (ms)", contractRegisterDurationSamples->make),
      ("Load Duration (ms)", loadDurationSamples->make),
      ("Handler Duration (ms)", handlerDurationSamples->make),
      ("DB Write Duration (ms)", dbWriteDurationSamples->make),
      ("Total Time Elapsed (ms)", totalTimeElapsedSamples->make),
    ]->Js.Dict.fromArray
  }

  let getTotalRunTime = (data: Data.t) =>
    DateFns.intervalToDuration({
      start: data.startTime,
      end: data.latestTime,
    })

  let getTotalEventProcessingTime = (data: Data.t) =>
    data.eventProcessing
    ->Array.reduce(0, (acc, eventProcessing) => acc + eventProcessing.totalTimeElapsed)
    ->DateFns.durationFromMillis

  let getTotalTimeFetchingChain = (data: Data.t, ~chainId) => {
    data.blockRangeFetched
    ->Array.reduce(0, (acc, blockRangeFetched) => {
      if blockRangeFetched.chainId == chainId {
        acc + blockRangeFetched.stats.totalTimeElapsed
      } else {
        acc
      }
    })
    ->DateFns.durationFromMillis
  }

  let printSummary = async () => {
    let data = await readFromCacheFile()
    switch data {
    | None =>
      Logging.error(
        "No benchmark cache file found, please use 'ENVIO_SAVE_BENCHMARK_DATA=true' and rerun the benchmark",
      )
    | Some(data) =>
      let config = RegisterHandlers.getConfig()
      let chainIds =
        config.chainMap
        ->ChainMap.keys
        ->Array.map(chain => chain->ChainMap.Chain.toChainId)
      Js.log("Time breakdown")
      [
        ("Total Runtime", data->getTotalRunTime),
        ("Total Time Processing", data->getTotalEventProcessingTime),
      ]
      ->Array.concat(
        chainIds->Array.map(chainId => {
          (
            "Total Time Fetching Chain " ++ chainId->Int.toString,
            data->getTotalTimeFetchingChain(~chainId),
          )
        }),
      )
      ->Js.Dict.fromArray
      ->logDictTable

      chainIds->Array.forEach(chainId => {
        Js.log2("BlockRangeFetched Summary for Chain", chainId)
        let chainBlockRangeFetchedSummary = data->getChainBlockRangeFetchedSummary(~chainId)
        chainBlockRangeFetchedSummary->logSummaryTable
      })

      Js.log("EventProcessing Summary")
      data->getEventProcessingSummary->logSummaryTable
    }
  }
}
